# EZ Toolkit Binary Distribution

This repository serves as a private distribution hub for precompiled binaries of my personal console applications. These tools are developed during personal time and are intended for private use by myself and authorized collaborators.

## Repository Structure
- **Releases:** All binaries are distributed through GitHub Releases
- **Meta Files:** Release metadata is stored in the `meta` directory:
  - `cmds.csv`: Available commands and their descriptions
  - `binaries.csv`: Individual binary files with checksums
  - `packages.csv`: Platform-specific packages with checksums
  - `signatures.json`: ECDSA digital signatures for all release files
- **Public Key:** `ezcrypt_public.pem` at the repository root

## Installation

### Quick Install (Recommended)

Set `EZTOOLKIT_ROOT` and add it to `PATH` first:

```bash
export EZTOOLKIT_ROOT=~/.eztoolkit
export PATH="$EZTOOLKIT_ROOT/bin:$PATH"
```

Then run the bootstrap script:

```bash
curl -fsSL https://raw.githubusercontent.com/elvinzeng/ez-toolkit-bin/master/install.sh | bash
```

This will automatically detect your platform, download the latest release package, and install all commands to `$EZTOOLKIT_ROOT/bin/`.

Don't forget to add the `export` lines above to your shell profile (`~/.bashrc`, `~/.zshrc`, etc.) to make them persistent.

### Manual Install

1. Visit the [Releases Page](https://github.com/elvinzeng/ez-toolkit-bin/releases)
2. Download platform package for your system: `ez-toolkit-<os>-<arch>-package-*.tar.xz`
3. Extract the package:
   ```bash
   tar -xf ez-toolkit-<os>-<arch>-package-*.tar.xz
   ```

## Documentation
For usage instructions and available options, please use the built-in help command:
```bash
<command> -h
# For example: ezt -h
```

## Supported Platforms
- Linux (amd64, arm64)
- macOS (amd64, arm64)
- Windows (amd64, arm64)

## Security & Verification

### Digital Signature Verification (Recommended)

All release files are signed with ECDSA (P-384). The authoritative public key is [`ezcrypt_public.pem`](ezcrypt_public.pem) in this repository's root directory. The same key is also included in each GitHub Release.

To verify a downloaded file using `ezcrypt`:

```bash
# 1. Download the public key and signatures.json from this repo or the release
# 2. Extract the signature for the target file:
python3 -c "
import json, base64, sys
with open('signatures.json') as f:
    data = json.load(f)
sys.stdout.buffer.write(base64.b64decode(data['<filename>']))
" > file.sig

# 3. Verify:
ezcrypt verify -k ezcrypt_public.pem -i <filename> -s file.sig
```

Example:
```bash
# Verify a package
python3 -c "
import json, base64, sys
with open('signatures.json') as f:
    data = json.load(f)
sys.stdout.buffer.write(base64.b64decode(data['ez-toolkit-darwin-arm64-package-20260328103000.tar.xz']))
" > pkg.sig

ezcrypt verify -k ezcrypt_public.pem -i ez-toolkit-darwin-arm64-package-20260328103000.tar.xz -s pkg.sig
# Output: Signature verified OK
```

### SHA256 Checksums (Quick Manual Verification)

All binaries also include SHA256 checksums in `meta/binaries.csv` and `meta/packages.csv` for quick manual verification:

```bash
# Verify a file's SHA256
shasum -a 256 <filename>
# Compare the output with the value in binaries.csv or packages.csv
```

### Key Rotation

If the signing key is ever rotated, the new public key will be committed to this repository. The latest `ezcrypt_public.pem` in this repository is always the authoritative key for verifying current releases.

## Access & Usage
- **Private Repository:** This is not an open-source project
- **Restricted Access:** Usage is limited to authorized individuals

## Disclaimer
These tools are developed for personal use and shared with trusted collaborators. They may not undergo extensive testing. Unauthorized use is strictly prohibited. No warranty is provided, and I take no responsibility for any consequences resulting from their use or misuse.
