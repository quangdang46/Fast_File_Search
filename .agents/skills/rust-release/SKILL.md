---
name: rust-release
description: Generic skill for releasing Rust workspace projects with cross-compilation, GitHub Releases, crates.io, and npm publishing. Covers the full lifecycle from version bump to multi-platform artifact upload.
---

# Rust Release Skill

Generic, reusable release checklist for any Rust workspace project that
cross-compiles to multiple targets and publishes artifacts to GitHub Releases,
crates.io, and/or npm.

## 1. Pre-release checklist

```
- [ ] All CI checks pass on the default branch (fmt, clippy, tests, bench-smoke)
- [ ] CHANGELOG / release notes drafted (or auto-generate via GitHub)
- [ ] Version string decided (semver: MAJOR.MINOR.PATCH or pre-release suffix)
```

## 2. Version bump

Use `cargo-edit` to set the version across the workspace:

```bash
cargo install cargo-edit   # if not already installed
cargo set-version <VERSION>
# or: make set-version V=<VERSION>  (if Makefile wraps it)
```

For npm companion packages, update each `package.json`:

```bash
# node -e script or `make set-npm-version PKG=<dir> VERSION=<ver>`
```

Commit the version bump on the default branch or a release branch.

## 3. Tagging

```bash
git tag v<VERSION>
git push origin v<VERSION>
```

Most workflows trigger on `push.tags: ["v*"]`. Pushing the tag kicks off the
full release pipeline.

## 4. Cross-compilation matrix

### Typical target matrix

| OS | Target triple | Tooling |
|---|---|---|
| Linux x86_64 (glibc) | `x86_64-unknown-linux-gnu` | `cargo-zigbuild` (pin glibc e.g. `.2.31`) |
| Linux aarch64 (glibc) | `aarch64-unknown-linux-gnu` | `cargo-zigbuild` |
| Linux x86_64 (musl) | `x86_64-unknown-linux-musl` | native or zigbuild |
| Linux aarch64 (musl) | `aarch64-unknown-linux-musl` | native or zigbuild |
| Android (Termux) | `aarch64-linux-android` | NDK clang (`android24-clang`) |
| macOS x86_64 | `x86_64-apple-darwin` | native `cargo build` |
| macOS aarch64 | `aarch64-apple-darwin` | native `cargo build` |
| Windows x86_64 | `x86_64-pc-windows-msvc` | native `cargo build` |
| Windows aarch64 | `aarch64-pc-windows-msvc` | native `cargo build` |

### CI build steps (per platform)

```yaml
# Linux (zigbuild for glibc portability)
- uses: mlugg/setup-zig@v2
  with: { version: "0.16.0" }
- run: cargo install cargo-zigbuild
- run: cargo zigbuild --profile ci --target $TARGET -p $PACKAGE --features $FEATURES

# macOS (set deployment target)
- run: MACOSX_DEPLOYMENT_TARGET="13" cargo build --profile ci --target $TARGET -p $PACKAGE
- run: codesign --force --sign - $ARTIFACT   # ad-hoc sign

# Windows (remove Git link.exe conflict first)
- shell: pwsh
  run: |
    $gitLink = "C:\Program Files\Git\usr\bin\link.exe"
    if (Test-Path $gitLink) { Rename-Item $gitLink "link.exe.bak" }
- run: cargo build --profile ci --target $TARGET -p $PACKAGE

# Android (NDK)
- run: |
    NDK_BIN="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
    export CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android24-clang"
    export CXX_aarch64_linux_android="$NDK_BIN/aarch64-linux-android24-clang++"
    export AR_aarch64_linux_android="$NDK_BIN/llvm-ar"
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_BIN/aarch64-linux-android24-clang"
    cargo build --profile ci --target $TARGET -p $PACKAGE
```

### Common gotchas

- **Windows `link.exe` conflict**: Git for Windows ships its own `link.exe` in
  `C:\Program Files\Git\usr\bin\`. Rename it before building.
- **macOS deployment target**: Set `MACOSX_DEPLOYMENT_TARGET` to avoid linker
  warnings when mixing Rust, cc-compiled C, and Zig-compiled objects.
- **glibc minimum**: Rust 1.91+ requires glibc >= 2.31. Use `cargo-zigbuild`
  with `x86_64-unknown-linux-gnu.2.31` to pin the minimum.

## 5. Build profiles

Recommended `Cargo.toml` profile for release artifacts:

```toml
[profile.release]
opt-level = 3
lto = "fat"
codegen-units = 1
strip = true

# CI profile: same as release but for automated builds
[profile.ci]
inherits = "release"
```

## 6. Artifact naming convention

```
# CLI binary
{binary}-{target}[.exe]           # e.g. ffs-x86_64-unknown-linux-musl

# Shared library (cdylib)
{lib}-{target}.{so|dylib|dll}     # e.g. c-lib-x86_64-apple-darwin.dylib

# MCP server or other binaries
{name}-{target}[.exe]

# SHA256 sidecar
{artifact}.sha256                 # one hash per file
```

## 7. GitHub Release job

```yaml
release:
  needs: [build-cli, build-lib]    # depend on all build jobs
  runs-on: ubuntu-latest
  if: startsWith(github.ref, 'refs/tags/v')
  permissions:
    contents: write
  steps:
    - uses: actions/download-artifact@v4
      with: { path: ./binaries }

    # Flatten artifact directories
    - run: |
        for dir in binaries/*/; do
          for file in "$dir"*; do
            [ -f "$file" ] && mv "$file" "binaries/$(basename "$file")"
          done
          rmdir "$dir" 2>/dev/null || true
        done

    # Generate SHA256 checksums
    - working-directory: ./binaries
      run: |
        for file in *; do
          [ -f "$file" ] && [[ ! "$file" == *.sha256 ]] && sha256sum "$file" > "${file}.sha256"
        done

    - uses: softprops/action-gh-release@v2
      with:
        files: ./binaries/*
        generate_release_notes: true
```

## 8. crates.io publishing

```bash
# Order matters — publish dependencies before dependents
CRATES_TO_PUBLISH="core-crate middleware-crate cli-crate"
for crate in $CRATES_TO_PUBLISH; do
  cargo publish -p "$crate" --allow-dirty
  sleep 30   # crates.io index propagation
done
```

Requires `CARGO_REGISTRY_TOKEN` secret in CI.

## 9. npm publishing (for native addon / FFI wrapper packages)

```bash
# Per-platform packages (contain the prebuilt .so/.dylib/.dll)
for pkg_dir in ./npm-packages/npm-*/; do
  cd "$pkg_dir"
  npm publish --tag "$TAG" --access public
  cd -
done

# Umbrella SDK package
cd packages/sdk
npm install && npm run build
npm publish --tag "$TAG" --access public
```

Requires `NPM_TOKEN` (automation token) secret in CI.

Tag strategy:
- Release tags → `npm publish --tag latest`
- Nightly / pre-release → `npm publish --tag nightly`

## 10. Installer scripts

### Unix (bash)

Key features for a robust installer:
- `detect_target()` via `uname -s` / `uname -m`
- Version resolution: GitHub API → redirect fallback
- Download with retry/resume (`curl -fL --retry 2 --continue-at -`)
- SHA256 checksum verification
- Atomic install (`install -m 0755` → `mv`)
- PATH management (`--easy-mode` appends to `.bashrc`/`.zshrc`)
- Lock file to prevent concurrent installs

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | bash
# With options:
curl -fsSL .../install.sh | bash -s -- --version v1.0.0 --easy-mode --verify
```

### Windows (PowerShell)

Key features:
- Architecture detection from registry (`PROCESSOR_ARCHITECTURE`)
- TLS 1.2 enforcement for PS 5.1 compatibility
- Prefer `curl.exe` over `Invoke-WebRequest` for speed
- Persistent PATH via `[Environment]::SetEnvironmentVariable('Path', ..., 'User')`
- Support piped execution: `irm .../install.ps1 | iex`

```powershell
irm https://raw.githubusercontent.com/OWNER/REPO/main/install.ps1 | iex
# With options (download first):
.\install.ps1 -Version v1.0.0 -EasyMode -Verify
```

## 11. Release workflow template

```yaml
name: Release
on:
  push:
    branches: [main]
    tags: ["v*"]
  pull_request:

jobs:
  build:
    name: Build ${{ matrix.target }}
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        include:
          - { os: ubuntu-latest,  target: x86_64-unknown-linux-musl }
          - { os: ubuntu-latest,  target: aarch64-unknown-linux-gnu, zigbuild_target: aarch64-unknown-linux-gnu.2.31 }
          - { os: macos-latest,   target: x86_64-apple-darwin }
          - { os: macos-latest,   target: aarch64-apple-darwin }
          - { os: windows-latest, target: x86_64-pc-windows-msvc }
          - { os: windows-latest, target: aarch64-pc-windows-msvc }
    steps:
      - uses: actions/checkout@v5
      - uses: mlugg/setup-zig@v2
        with: { version: "0.16.0" }
      - run: rustup target add ${{ matrix.target }}
      - run: cargo install cargo-zigbuild
        if: contains(matrix.os, 'ubuntu')
      # ... build per platform (see section 4)
      - uses: actions/upload-artifact@v4
        with:
          name: ${{ matrix.target }}
          path: ./output/*

  release:
    needs: [build]
    if: startsWith(github.ref, 'refs/tags/v')
    # ... see section 7

  publish-crates:
    needs: [build]
    if: startsWith(github.ref, 'refs/tags/v')
    # ... see section 8

  publish-npm:
    needs: [build]
    if: startsWith(github.ref, 'refs/tags/v')
    # ... see section 9
```

## 12. Nightly releases

For continuous delivery without manual tagging:

```yaml
# In the release job condition:
if: github.event_name != 'pull_request'

# Version scheme:
# Tagged push (v*) → full release, generate_release_notes: true
# Main branch push → nightly, prerelease: true
#   version: 0.7.3-nightly.<short-sha>
```

Use a Lua/shell script to determine version dynamically based on
`git describe --tags` and the current commit SHA.
