#!/bin/sh
# install.sh — bootstrap installer for Elvin Zeng's ez-toolkit CLI toolkit.
#
# Trust model (two-phase; see design spec §13):
#   Phase 1: HTTPS + SHA256. The integrity chain is anchored in
#            meta/bootstrap-index.conf (which carries per-platform package
#            SHA256s) fetched over HTTPS from GitHub.
#   Phase 2: Once ezcrypt has been extracted from the package, use it to
#            cryptographically verify the release manifest and every
#            installed binary against ezcrypt_public.pem (the trust root
#            also downloaded in Phase 1). ezt's hardcoded public key is
#            the final backstop on any subsequent run.
#
# POSIX sh strict: no bashisms. Verified with `shellcheck -s sh` and `dash -n`.
#   - `[ ]` not `[[ ]]`
#   - `printf` not `echo -e`
#   - `.` (dot) not `source`
#   - no arrays, no `local`, no `<()`, no `${var,,}`, no `=~`, no brace expansion
#   - `command -v` not `which`
set -e

# -----------------------------------------------------------------------------
# Phase 0: dependency preflight
# -----------------------------------------------------------------------------
# Every command this script relies on is checked up front, so a missing
# dependency is reported as a missing dependency. Without this, the failure
# surfaces several steps later wearing the wrong name — a machine without
# `xz` used to abort with "Failed to list archive contents", which reads
# like a corrupt download.
missing=""
for cmd in curl tar mktemp find basename grep cut tr uname; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
done

# sha256: GNU coreutils ships sha256sum, BSD/macOS ships shasum. Either
# satisfies step 5, so this is an or-check rather than part of the loop.
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    missing="$missing sha256sum(or-shasum)"
fi

# xz: the release packages are .tar.xz and step 6 unpacks them with `tar -J`.
# GNU tar implements -J by forking the external `xz` binary, so on Linux the
# xz-utils package is a hard requirement. BSD tar (macOS, and anything else
# built on libarchive) links liblzma directly and needs no external binary —
# which is why this gap never showed up on macOS. Probe accordingly instead
# of demanding xz everywhere.
if ! command -v xz >/dev/null 2>&1; then
    case "$(tar --version 2>/dev/null)" in
        *bsdtar*|*libarchive*) ;;
        *) missing="$missing xz" ;;
    esac
fi

if [ -n "$missing" ]; then
    printf 'Missing required command(s):%s\n' "$missing" >&2
    printf '  Install them and re-run. On Debian/Ubuntu, the packages are\n' >&2
    printf '  usually named after the commands (xz lives in xz-utils).\n' >&2
    exit 1
fi

# EZTOOLKIT_ROOT must be EXPORTED, not merely set: the ezcrypt invoked in
# Phase 2 is a child process, and every ezcli binary refuses to run without
# this variable in its environment. A bare assignment leaves it invisible to
# children, so on a machine where the user's profile has not already exported
# it, ezcrypt exits before doing any crypto at all.
EZTOOLKIT_ROOT="${EZTOOLKIT_ROOT:-$HOME/.eztoolkit}"
export EZTOOLKIT_ROOT
REPO_RAW="https://raw.githubusercontent.com/elvinzeng/ez-toolkit-bin/master"
GH_API="https://api.github.com/repos/elvinzeng/ez-toolkit-bin"

# Create directories individually (POSIX sh has no brace expansion).
mkdir -p "$EZTOOLKIT_ROOT/bin"
mkdir -p "$EZTOOLKIT_ROOT/signatures"
mkdir -p "$EZTOOLKIT_ROOT/conf"
mkdir -p "$EZTOOLKIT_ROOT/cache/ezt"
mkdir -p "$EZTOOLKIT_ROOT/logs/ezt"

# ezcli binaries also refuse to run unless $EZTOOLKIT_ROOT/bin is on PATH
# (see ezcli internal/cmdbase/prerun.go). That check exists to keep users
# from installing commands they cannot then invoke, but it applies to every
# ezcli binary including the ezcrypt this script drives during bootstrap —
# and during bootstrap the profile edit printed at the end has not happened
# yet. Prepend it for the duration of this run so Phase 2 can proceed.
# The staged ezcrypt is still invoked by absolute path, so this affects the
# preflight check only, never which binary runs.
case ":$PATH:" in
    *":$EZTOOLKIT_ROOT/bin:"*) ;;
    *) PATH="$EZTOOLKIT_ROOT/bin:$PATH" ;;
esac
export PATH

# All temp state is created via mktemp for two reasons:
#   1. `$$` makes filenames predictable (PID), which opens a /tmp symlink
#      attack window: an attacker can pre-plant a symlink at
#      /tmp/foo.<predicted-pid> pointing at any writable file, and curl -o
#      would then overwrite it. mktemp creates an unpredictable path
#      atomically with mode 600.
#   2. We need a staging directory for tar extraction — see Phase 1 step 6.
#
# TMPDIR honored (Android/Termux, sandbox environments, etc.).
: "${TMPDIR:=/tmp}"
export TMPDIR

BOOTSTRAP_INDEX=""
PKG_TMP=""
STAGE_DIR=""
VERIFY_LOG=""

cleanup() {
    [ -n "$BOOTSTRAP_INDEX" ] && rm -f "$BOOTSTRAP_INDEX"
    [ -n "$PKG_TMP" ] && rm -f "$PKG_TMP"
    [ -n "$STAGE_DIR" ] && rm -rf "$STAGE_DIR"
    [ -n "$VERIFY_LOG" ] && rm -f "$VERIFY_LOG"
    return 0
}
trap cleanup EXIT INT TERM

BOOTSTRAP_INDEX=$(mktemp -t ez-toolkit-bootstrap-index.XXXXXXXXXX) || {
    printf 'Failed to create temp file for bootstrap index\n' >&2
    exit 1
}
PKG_TMP=$(mktemp -t ez-toolkit-pkg.XXXXXXXXXX) || {
    printf 'Failed to create temp file for package\n' >&2
    exit 1
}
STAGE_DIR=$(mktemp -d -t ez-toolkit-stage.XXXXXXXXXX) || {
    printf 'Failed to create staging directory\n' >&2
    exit 1
}
# Phase 2 captures ezcrypt's output here so it can be replayed verbatim on
# failure. It lives outside $STAGE_DIR so the step-9 glob over the staged
# package never sees it.
VERIFY_LOG=$(mktemp -t ez-toolkit-verify.XXXXXXXXXX) || {
    printf 'Failed to create temp file for verification output\n' >&2
    exit 1
}

# -----------------------------------------------------------------------------
# Phase 1: HTTPS + SHA256
# -----------------------------------------------------------------------------

# 1. Detect platform.
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) printf 'Unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

# 2. Download bootstrap-index.conf (HTTPS trust) and extract data from it.
#
#    SECURITY: bootstrap-index.conf is NEVER sourced / executed as shell
#    code. It is treated as a pure data file: we grep for the exact
#    variable names we need and extract their values. This prevents an
#    attacker who compromises the GitHub repo from injecting arbitrary
#    shell commands — the file can only influence which package filename
#    and sha256 are used, not what code runs on the user's machine.
#
#    The signed release-manifest.toml covers the same (filename, sha256)
#    data, so any tampering is caught transitively when Phase 2 verifies
#    the manifest against ezcrypt_public.pem.
curl -fsSL "$REPO_RAW/meta/bootstrap-index.conf" -o "$BOOTSTRAP_INDEX"

# extract_var: read a variable value from bootstrap-index.conf without
# executing it. Matches lines of the form: VAR_NAME="value"
# Returns the unquoted value, or empty string if not found.
extract_var() {
    # grep for the exact variable name at line start, extract the quoted value
    _line=$(grep "^${1}=" "$BOOTSTRAP_INDEX" 2>/dev/null) || true
    case "$_line" in
        *=*)
            # strip everything up to and including the first =
            _val="${_line#*=}"
            # strip surrounding quotes (single or double)
            _val="${_val#\"}" ; _val="${_val%\"}"
            _val="${_val#\'}" ; _val="${_val%\'}"
            printf '%s' "$_val"
            ;;
    esac
}

# 3. Resolve package name and SHA for this platform.
#    Explicit `case` lookup keeps the trust boundary obvious: only the
#    platforms listed below reach the download stage. Variable names
#    match the bootstrap-index.conf format: PKG_<os>_<arch>, SHA_<os>_<arch>.
case "$OS/$ARCH" in
    linux/amd64)
        PKG_NAME=$(extract_var PKG_linux_amd64)
        PKG_SHA=$(extract_var SHA_linux_amd64)
        ;;
    linux/arm64)
        PKG_NAME=$(extract_var PKG_linux_arm64)
        PKG_SHA=$(extract_var SHA_linux_arm64)
        ;;
    darwin/amd64)
        PKG_NAME=$(extract_var PKG_darwin_amd64)
        PKG_SHA=$(extract_var SHA_darwin_amd64)
        ;;
    darwin/arm64)
        PKG_NAME=$(extract_var PKG_darwin_arm64)
        PKG_SHA=$(extract_var SHA_darwin_arm64)
        ;;
    windows/amd64)
        PKG_NAME=$(extract_var PKG_windows_amd64)
        PKG_SHA=$(extract_var SHA_windows_amd64)
        ;;
    windows/arm64)
        PKG_NAME=$(extract_var PKG_windows_arm64)
        PKG_SHA=$(extract_var SHA_windows_arm64)
        ;;
    *)
        printf 'Unsupported platform: %s/%s\n' "$OS" "$ARCH" >&2
        exit 1
        ;;
esac

if [ -z "$PKG_NAME" ] || [ -z "$PKG_SHA" ]; then
    printf 'No package available for %s/%s in this release\n' "$OS" "$ARCH" >&2
    exit 1
fi

# 4. Download the package asset from the latest GitHub Release.
RELEASE_JSON=$(curl -fsSL "$GH_API/releases/latest")
ASSET_URL=$(printf '%s' "$RELEASE_JSON" | grep -o "https://[^\"]*${PKG_NAME}" | head -1)
if [ -z "$ASSET_URL" ]; then
    printf 'Could not locate asset URL for %s in latest release\n' "$PKG_NAME" >&2
    exit 1
fi
curl -fsSL "$ASSET_URL" -o "$PKG_TMP"

# 5. SHA256 check (integrity only; authenticity comes in Phase 2).
#    sha256sum is GNU; shasum is BSD/macOS. Accept either.
if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL=$(sha256sum "$PKG_TMP" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
    ACTUAL=$(shasum -a 256 "$PKG_TMP" | cut -d' ' -f1)
else
    printf 'Neither sha256sum nor shasum is available on this system\n' >&2
    exit 1
fi
if [ "$ACTUAL" != "$PKG_SHA" ]; then
    printf 'SHA256 mismatch for %s\n' "$PKG_NAME" >&2
    printf '  expected: %s\n' "$PKG_SHA" >&2
    printf '  actual:   %s\n' "$ACTUAL" >&2
    exit 1
fi

# 6. Extract the package into a staging directory (NOT directly into
#    $EZTOOLKIT_ROOT/bin). Staging lets Phase 2 verify signatures before
#    any bytes reach the user's PATH. Because the tar archive is still
#    cryptographically unauthenticated at this point (its SHA256 is
#    sourced from bootstrap-index.conf, which itself is not yet verified),
#    we MUST defend against malicious archive contents before running
#    the extraction that moves them to disk.
#
#    Defense is three-part:
#      (a) Pre-list tar entries and reject absolute paths, `..` traversal,
#          and any entry whose name contains a newline or embedded NUL
#          (which would confuse subsequent POSIX sh loops).
#      (b) Extract to staging and then walk the staging tree with `find`,
#          aborting if any entry is a symlink, hardlink, device node,
#          socket, or fifo. Only regular files and directories are
#          allowed to reach Phase 2.
#      (c) Phase 2 verifies signatures, and only files with a `.ezg`
#          sibling are promoted to bin/ — MANIFEST and any other non-
#          binary filler is discarded.
#
#    tar -J (xz) is not in POSIX tar but is supported by GNU tar, BSD tar,
#    and busybox tar when compiled with xz. Falling back to a two-step
#    `xz -d` + `tar -xf` would complicate error handling, so we require it.
#    Phase 0 verifies that requirement is actually met before we get here.

# Pre-check 1: entry types. Use long-form `tar -tv` and reject any entry
# whose first column (the type char) is not `-` (regular file) or `d`
# (directory). This rejects symlinks (l), hardlinks (h), device nodes
# (b/c), fifos (p), sockets (s). Rejection happens BEFORE extraction so
# that a malicious archive cannot create a symlink and then a same-named
# regular file that writes through the symlink to an attacker-chosen
# path. The `-tv` output format is consistent across GNU tar, BSD tar,
# and busybox tar at the first-column level.
tar_long=$(tar -tvJf "$PKG_TMP") || {
    printf 'Failed to list archive contents (long form)\n' >&2
    printf '  If tar reported that it could not exec xz, this tar needs the\n' >&2
    printf '  external xz binary for -J. Phase 0 should have caught that;\n' >&2
    printf '  otherwise the downloaded package is corrupt.\n' >&2
    exit 1
}
printf '%s\n' "$tar_long" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    type_char=$(printf '%s' "$line" | cut -c1)
    case "$type_char" in
        -|d) ;;
        *)
            printf 'Rejecting non-regular tar entry (type=%s): %s\n' \
                "$type_char" "$line" >&2
            exit 1 ;;
    esac
done || exit 1

# Pre-check 2: entry paths. Use short-form `tar -t` (paths only, no
# link-target noise to parse) and reject absolute paths, `..` traversal,
# and names containing tabs (which would confuse subsequent POSIX sh
# loops that build positional-parameter argv for ezcrypt). Newlines in
# filenames are implicitly rejected because `read -r` reads one line,
# and any second line would be re-fed through the same case check and
# fail one of the other patterns. Patterns:
#   /*        absolute path
#   ../*      starts with parent traversal
#   ..        entry is literally ".."
#   */..      ends with "/.."
#   */../*    contains "/../" anywhere
tar_paths=$(tar -tJf "$PKG_TMP") || {
    printf 'Failed to list archive contents (short form)\n' >&2
    exit 1
}
printf '%s\n' "$tar_paths" | while IFS= read -r entry; do
    case "$entry" in
        '')                                continue ;;
        /*|../*|..|*/..|*/../*|*'	'*)
            printf 'Rejecting dangerous tar entry: %s\n' "$entry" >&2
            exit 1 ;;
    esac
done || exit 1

# Pre-checks passed — safe to extract.
tar -xJf "$PKG_TMP" -C "$STAGE_DIR"

# Belt-and-braces: scan the extracted tree for anything that isn't a
# regular file or directory. This is redundant with the pre-check above
# (which used `-tv` long form), but the cost is negligible and it
# catches any drift between `tar -tv` output format and actual tar
# extraction behavior on exotic inputs.
nonregular=$(find "$STAGE_DIR" \
    \( -type l -o -type b -o -type c -o -type p -o -type s \) -print 2>/dev/null)
if [ -n "$nonregular" ]; then
    printf 'Extracted tree contains non-regular-file entries, aborting:\n%s\n' \
        "$nonregular" >&2
    exit 1
fi

# 7. Download the public key and the signed artifacts used in Phase 2.
#    The public key lands in $STAGE_DIR (not $EZTOOLKIT_ROOT/conf/) because
#    it is only needed during this install run — `ezcrypt verify -k` requires
#    a filesystem path, and after Phase 2 promotes binaries, nothing reads
#    this pem again. The EXIT trap removes $STAGE_DIR (success or failure)
#    so the pem does not linger in the user's toolkit root.
#    (ezt at runtime uses its own //go:embed copy of the pubkey for any
#    subsequent verify/install/upgrade — see cmd/ezt/keys_production.go.)
curl -fsSL "$REPO_RAW/ezcrypt_public.pem" \
    -o "$STAGE_DIR/ezcrypt_public.pem"
curl -fsSL "$REPO_RAW/meta/release-manifest.toml" \
    -o "$EZTOOLKIT_ROOT/cache/ezt/release-manifest.toml"
curl -fsSL "$REPO_RAW/meta/release-manifest.toml.ezg" \
    -o "$EZTOOLKIT_ROOT/cache/ezt/release-manifest.toml.ezg"
curl -fsSL "$REPO_RAW/meta/bootstrap-index.conf.ezg" \
    -o "$EZTOOLKIT_ROOT/cache/ezt/bootstrap-index.conf.ezg"

# -----------------------------------------------------------------------------
# Phase 2: ezcrypt verification (against the staged binaries)
# -----------------------------------------------------------------------------

# Binary names inside the package carry a platform suffix (e.g.
# ezcrypt_darwin_arm64). Windows binaries also have .exe.
case "$OS" in
    windows) EZCRYPT="$STAGE_DIR/ezcrypt_${OS}_${ARCH}.exe" ;;
    *)       EZCRYPT="$STAGE_DIR/ezcrypt_${OS}_${ARCH}" ;;
esac
PUB="$STAGE_DIR/ezcrypt_public.pem"
MANIFEST="$EZTOOLKIT_ROOT/cache/ezt/release-manifest.toml"
MANIFEST_SIG="$EZTOOLKIT_ROOT/cache/ezt/release-manifest.toml.ezg"

if [ ! -x "$EZCRYPT" ]; then
    printf 'WARNING: ezcrypt was not present in the staged package\n' >&2
    printf '  Bootstrap aborted: integrity cannot be cryptographically verified.\n' >&2
    exit 2
fi

# 8. Verify the release manifest signature.
#
#    Output is captured rather than discarded, and replayed verbatim when
#    ezcrypt exits non-zero. A non-zero exit does NOT prove the signature is
#    bad — ezcrypt also refuses to start when its own environment precondi-
#    tions are unmet, and those exits are indistinguishable from a real
#    verification failure by exit code alone. Discarding stderr here once
#    turned "EZTOOLKIT_ROOT is not set" into a reported signature failure and
#    sent the investigation after a key-rotation theory for a day. Never
#    reintroduce `2>&1` on this call: the abort message states what is
#    certain (the check did not pass), and ezcrypt's own words supply why.
if ! "$EZCRYPT" verify -k "$PUB" -i "$MANIFEST" -s "$MANIFEST_SIG" >"$VERIFY_LOG" 2>&1; then
    printf 'WARNING: manifest signature check did not pass\n' >&2
    printf '  ezcrypt exited non-zero. Its output was:\n' >&2
    sed 's/^/    | /' "$VERIFY_LOG" >&2
    printf '  This is either a genuine signature failure or an ezcrypt startup\n' >&2
    printf '  error — the message above distinguishes them.\n' >&2
    printf '  Bootstrap aborted: integrity could not be cryptographically verified.\n' >&2
    exit 2
fi
printf 'OK manifest signature verified\n'

# 9. Batch-verify every staged binary in a single ezcrypt invocation.
#    install.sh only reports pass/fail; for per-file details run `ezt verify`.
#
#    Filenames come from the UNAUTHENTICATED archive, so we must accumulate
#    them into POSIX positional parameters ("$@") instead of a space-
#    separated string. String-based concatenation + word splitting would
#    break on any filename containing whitespace, and would also silently
#    reinterpret a filename like `-rm` as an ezcrypt flag. Positional
#    parameter accumulation preserves one filename per argv slot and
#    passes it through to ezcrypt verbatim.
set --
for bin in "$STAGE_DIR"/*; do
    case "$bin" in
        *.ezg) continue ;;
    esac
    [ -f "$bin" ] || continue
    [ -f "${bin}.ezg" ] || continue
    set -- "$@" -i "$bin"
done

if [ "$#" -eq 0 ]; then
    printf 'WARNING: no binaries with .ezg sibling found in package, aborting\n' >&2
    exit 3
fi

#    As in step 8, ezcrypt's output is captured and replayed on failure
#    rather than discarded — see the reasoning there.
if ! "$EZCRYPT" verify -k "$PUB" "$@" -s "$STAGE_DIR" >"$VERIFY_LOG" 2>&1; then
    printf 'WARNING: binary signature check did not pass\n' >&2
    printf '  ezcrypt exited non-zero. Its output was:\n' >&2
    sed 's/^/    | /' "$VERIFY_LOG" >&2
    printf '  Bootstrap aborted: the staged binaries were NOT installed.\n' >&2
    exit 3
fi
printf 'OK all binary signatures verified\n'

# 10. All Phase 2 checks passed — promote verified files:
#       binaries  → $EZTOOLKIT_ROOT/bin/        (on PATH, only executables)
#       .ezg sigs → $EZTOOLKIT_ROOT/signatures/ (off PATH, no tab-complete noise)
#
#     We iterate the same "$@" we built for verify, stepping two args at
#     a time (-i <path>), so the move set is exactly the set of files
#     that cleared signature verification. MANIFEST and other non-binary
#     filler is left in staging and swept by the cleanup trap.
SUFFIX="_${OS}_${ARCH}"
case "$OS" in
    windows) SUFFIX="_${OS}_${ARCH}.exe" ;;
esac
while [ "$#" -gt 0 ]; do
    # "$1" is "-i", "$2" is the staged binary path.
    shift
    src="$1"
    shift
    fullname=$(basename "$src")
    # Strip the platform suffix so users get bare command names on PATH
    # (e.g. ezcrypt_darwin_arm64 → ezcrypt).
    name="${fullname%"$SUFFIX"}"
    mv -f "$src" "$EZTOOLKIT_ROOT/bin/$name"
    mv -f "${src}.ezg" "$EZTOOLKIT_ROOT/signatures/${name}.ezg"
done

# 11. Cleanup (belt-and-braces: the EXIT trap also handles this path, but
#     running it here keeps the final message uncluttered).
cleanup
BOOTSTRAP_INDEX=""
PKG_TMP=""
STAGE_DIR=""

printf '\n'
printf 'Bootstrap complete. Add this to your shell profile:\n'
# The $PATH below is deliberately literal — this line is advice text the user
# copies into a shell profile, where $PATH must be expanded at that time, not
# now. Expanding it here would paste the installing machine's entire PATH.
# shellcheck disable=SC2016
printf '  export PATH="%s/bin:$PATH"\n' "$EZTOOLKIT_ROOT"
