#!/bin/bash
#
# EZ Toolkit Bootstrap Script
#
# One-click install: downloads the latest platform package from GitHub Release,
# extracts all commands, and installs them to $EZTOOLKIT_ROOT/bin/.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/elvinzeng/ez-toolkit-bin/master/install.sh | bash
#
# Prerequisites:
#   - EZTOOLKIT_ROOT environment variable must be set (e.g. $HOME/.eztoolkit)
#   - $EZTOOLKIT_ROOT/bin must be in PATH
#   - curl, tar, xz must be available

set -euo pipefail

REPO="elvinzeng/ez-toolkit-bin"

# --- Helpers ---

die() {
    echo "Error: $*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

# --- Pre-flight checks ---

[ -n "${EZTOOLKIT_ROOT:-}" ] || die "EZTOOLKIT_ROOT is not set. Please set it first (e.g. export EZTOOLKIT_ROOT=\"\$HOME/.eztoolkit\")."

case "$EZTOOLKIT_ROOT" in
    ~*) die "EZTOOLKIT_ROOT contains a literal '~' ($EZTOOLKIT_ROOT). Use \$HOME instead (e.g. export EZTOOLKIT_ROOT=\"\$HOME/.eztoolkit\")." ;;
esac

case ":$PATH:" in
    *":${EZTOOLKIT_ROOT}/bin:"*) ;;
    *) die "\$EZTOOLKIT_ROOT/bin is not in PATH. Please add it first (e.g. export PATH=\"\$EZTOOLKIT_ROOT/bin:\$PATH\")." ;;
esac

for cmd in curl tar xz; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not found. Please install it first."
done

# --- Detect platform ---

detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "darwin" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *) die "Unsupported OS: $(uname -s)" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) die "Unsupported architecture: $(uname -m)" ;;
    esac
}

OS=$(detect_os)
ARCH=$(detect_arch)

info "Detected platform: ${OS}/${ARCH}"

# --- Create directories ---

DIRS=(bin conf logs data cache/ezt temp)
for d in "${DIRS[@]}"; do
    mkdir -p "${EZTOOLKIT_ROOT}/${d}"
done

info "Directories created under ${EZTOOLKIT_ROOT}"

# --- Find latest release and matching package ---

info "Fetching latest release info from GitHub..."

RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")

# Find the package asset for current platform
PACKAGE_NAME=$(echo "$RELEASE_JSON" | grep -o "\"ez-toolkit-${OS}-${ARCH}-package-[^\"]*\.tar\.xz\"" | tr -d '"')
[ -n "$PACKAGE_NAME" ] || die "No package found for ${OS}/${ARCH} in the latest release."

DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o "\"https://[^\"]*/${PACKAGE_NAME}\"" | tr -d '"')
[ -n "$DOWNLOAD_URL" ] || die "Failed to extract download URL for ${PACKAGE_NAME}."

# --- Download package to cache ---

CACHE_DIR="${EZTOOLKIT_ROOT}/cache/ezt"
PACKAGE_PATH="${CACHE_DIR}/${PACKAGE_NAME}"

info "Downloading ${PACKAGE_NAME}..."
curl -fSL --progress-bar -o "$PACKAGE_PATH" "$DOWNLOAD_URL"

# --- Extract and install ---

EXTRACT_DIR="${EZTOOLKIT_ROOT}/temp/bootstrap_extract"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

info "Extracting package..."
tar -xf "$PACKAGE_PATH" -C "$EXTRACT_DIR"

# Binary files in the package are named: {cmd}_{os}_{arch}[.exe]
# Install them to $EZTOOLKIT_ROOT/bin/{cmd}[.exe]
INSTALLED=0
for file in "${EXTRACT_DIR}"/*; do
    [ -f "$file" ] || continue
    basename=$(basename "$file")

    # Strip _{os}_{arch} suffix to get the command name
    if [ "$OS" = "windows" ]; then
        cmd_name=$(echo "$basename" | sed "s/_${OS}_${ARCH}\.exe$/.exe/")
    else
        cmd_name=$(echo "$basename" | sed "s/_${OS}_${ARCH}$//")
    fi

    cp "$file" "${EZTOOLKIT_ROOT}/bin/${cmd_name}"
    chmod +x "${EZTOOLKIT_ROOT}/bin/${cmd_name}"
    INSTALLED=$((INSTALLED + 1))
done

rm -rf "$EXTRACT_DIR"

info "Installed ${INSTALLED} command(s) to ${EZTOOLKIT_ROOT}/bin/"

# --- Download metadata files to cache ---

TAG=$(echo "$RELEASE_JSON" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//;s/"//')

for meta_file in signatures.json ezcrypt_public.pem; do
    META_URL="https://github.com/${REPO}/releases/download/${TAG}/${meta_file}"
    curl -fsSL -o "${CACHE_DIR}/${meta_file}" "$META_URL" 2>/dev/null || true
done

# --- Done ---

info "Bootstrap complete!"
echo ""
echo "Make sure these lines are in your shell profile (~/.bashrc or ~/.zshrc):"
echo ""
echo "  export EZTOOLKIT_ROOT=\"\$HOME/.eztoolkit\""
echo "  export PATH=\"\$EZTOOLKIT_ROOT/bin:\$PATH\""
echo ""
echo "Then run 'ezt' to verify the installation."
