# Custom Vulkan SDK Builder

This repository builds small Vulkan SDK-style packages for individual OS/CPU targets.

Each package contains:

- Vulkan headers and registry files
- the Vulkan loader for the target platform
- Slang by default, including `slangc` and Slang libraries/headers
- setup helpers: `setup-env.sh` and `setup-env.ps1`

It does **not** include a GPU driver. Target machines still need a Vulkan-capable ICD/driver installed separately.

## GitHub Actions targets

The `build-vulkan-sdk` workflow builds one artifact per platform/architecture:

| Platform | Architecture | Runner | Artifact |
| --- | --- | --- | --- |
| Linux | `x86_64` | `ubuntu-22.04` | `custom-vulkan-sdk-linux-x86_64.tar.gz` |
| Linux | `aarch64` | `ubuntu-22.04-arm` | `custom-vulkan-sdk-linux-aarch64.tar.gz` |
| macOS | `x86_64` | `macos-15-intel` | `custom-vulkan-sdk-macos-x86_64.tar.gz` |
| macOS | `aarch64` | `macos-15` | `custom-vulkan-sdk-macos-aarch64.tar.gz` |
| Windows | `x86_64` | `windows-2022` | `custom-vulkan-sdk-windows-x86_64.zip` |
| Windows | `aarch64` | `windows-11-arm` | `custom-vulkan-sdk-windows-aarch64.zip` |

The packages are intentionally **not** merged together. Download only the artifact matching the machine where you will use it.

Linux artifacts are built on Ubuntu 22.04, giving them a glibc 2.35 baseline suitable for recent Debian, Ubuntu, Fedora, and Arch Linux systems.

## Build on GitHub Actions

Push this repository to GitHub, then open the **Actions** tab and run the `build-vulkan-sdk` workflow. It also runs automatically on pushes and pull requests.

Manual workflow inputs let you choose refs for:

- `KhronosGroup/Vulkan-Headers`
- `KhronosGroup/Vulkan-Loader`
- `shader-slang/slang`

Slang is included by default. You can disable it with the `build_slang` workflow input if you only want headers and the Vulkan loader.

## Use a package

Linux/macOS:

```bash
tar -xzf custom-vulkan-sdk-linux-x86_64.tar.gz
source custom-vulkan-sdk/setup-env.sh
slangc -version
```

Windows PowerShell:

```powershell
Expand-Archive .\custom-vulkan-sdk-windows-x86_64.zip
. .\custom-vulkan-sdk\setup-env.ps1
slangc.exe -version
```

The setup scripts set `VULKAN_SDK`, update `PATH`, and add include/CMake search paths for the selected platform/architecture package.

## Manual native build

Use the same build script locally on the target machine.

Linux Debian/Ubuntu dependencies:

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  cmake ninja-build git python3 pkg-config file binutils \
  build-essential \
  libwayland-dev libx11-dev libx11-xcb-dev libxcb1-dev libxrandr-dev
```

Linux build examples:

```bash
scripts/build-sdk.sh linux x86_64
scripts/verify-sdk.sh dist/custom-vulkan-sdk linux x86_64

tar -C dist -czf custom-vulkan-sdk-linux-x86_64.tar.gz \
  custom-vulkan-sdk/linux-x86_64 \
  custom-vulkan-sdk/setup-env.sh \
  custom-vulkan-sdk/setup-env.ps1
```

macOS build example:

```bash
brew install ninja
scripts/build-sdk.sh macos aarch64
scripts/verify-sdk.sh dist/custom-vulkan-sdk macos aarch64
```

Windows build example from Git Bash:

```bash
scripts/build-sdk.sh windows x86_64
scripts/verify-sdk.sh dist/custom-vulkan-sdk windows x86_64
```

## Pin source versions

By default, the build uses upstream default refs: Vulkan repositories use `main`, and Slang uses `master`. For reproducible builds, set matching tags or commits:

```bash
VULKAN_HEADERS_REF=v1.4.309 \
VULKAN_LOADER_REF=v1.4.309 \
SLANG_REF=v2025.21 \
scripts/build-sdk.sh linux x86_64
```

## Options

Common environment variables:

```bash
BUILD_SLANG=ON            # ON/OFF, default ON
SLANG_REF=master          # Slang git ref
SLANG_LLVM_FLAVOR=DISABLE # avoids optional Slang LLVM binary downloads
SLANG_ENABLE_DXIL=OFF     # set ON if you need DXIL support
ENABLE_WSI=ON             # Linux loader WSI support: XCB/Xlib/Xrandr/Wayland
JOBS=4                    # parallel build jobs
```

If you need a more headless/minimal Linux loader build:

```bash
ENABLE_WSI=OFF scripts/build-sdk.sh linux x86_64
```
