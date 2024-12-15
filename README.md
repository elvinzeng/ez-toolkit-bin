# EZ Toolkit Binary Distribution

This repository serves as a private distribution hub for precompiled binaries of my personal console applications. These tools are developed during personal time and are intended for private use by myself and authorized collaborators.

## Repository Structure
- **Releases:** All binaries are distributed through GitHub Releases
- **Meta Files:** Release metadata is stored in the `meta` directory:
  - `cmds.csv`: Available commands and their descriptions
  - `binaries.csv`: Individual binary files with checksums
  - `packages.csv`: Platform-specific packages with checksums

## Installation
1. Visit the [Releases Page](https://github.com/elvinzeng/ez-toolkit-bin/releases)
2. Download either:
   - Individual command binaries (`<command>_<os>_<arch>.xz`)
   - Platform packages (`ez-toolkit-<os>-<arch>-package-*.tar.xz`)
3. Extract the files:
   ```bash
   # For individual commands
   xz -d <command>_<os>_<arch>.xz

   # For platform packages
   tar -xf ez-toolkit-<os>-<arch>-package-*.tar.xz
   ```

## Supported Platforms
- Linux (amd64, arm64)
- macOS (amd64, arm64)
- Windows (amd64, arm64)

## Security & Usage
- **Private Repository:** This is not an open-source project
- **Restricted Access:** Usage is limited to authorized individuals
- **File Verification:** All binaries include SHA256 checksums for verification

## Disclaimer
These tools are developed for personal use and shared with trusted collaborators. They may not undergo extensive testing. Unauthorized use is strictly prohibited. No warranty is provided, and I take no responsibility for any consequences resulting from their use or misuse.
