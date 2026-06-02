# Custom Vulkan SDK Builder

This repository builds a small Linux Vulkan SDK bundle containing:

- architecture-independent Vulkan headers and registry files in `common/`
- a Linux `x86_64` Vulkan loader install tree in `linux-x86_64/`
- a Linux `aarch64` Vulkan loader install tree in `linux-aarch64/`
- `include` and registry symlinks inside each architecture tree for standard `$VULKAN_SDK`-style usage
- a `setup-env.sh` helper that selects the right architecture at runtime

The bundle is intentionally minimal. It builds `Vulkan-Headers` and `Vulkan-Loader`; it does not include a GPU driver, validation layers, shader tools, or `vulkaninfo` yet.

## Distro compatibility

The GitHub workflow builds natively on Ubuntu runners for each CPU architecture: `ubuntu-22.04` for `x86_64` and `ubuntu-22.04-arm` for `aarch64`. That avoids cross-compilation sysroot issues while keeping a glibc 2.35 baseline, which is suitable for recent Debian releases, Ubuntu, Fedora, and Arch Linux.

The workflow also runs `scripts/check-compat.sh` to verify that the checked ELF files do not require a glibc version newer than `GLIBC_2.35`.

Target machines still need:

- the same CPU architecture as the selected SDK tree: `x86_64` or `aarch64`
- glibc 2.35 or newer
- a Vulkan-capable ICD/driver installed separately

## Build on GitHub Actions

Push this repository to GitHub, then open the **Actions** tab and run the `build-vulkan-sdk` workflow. The workflow also runs automatically on pushes and pull requests. Your GitHub account/repository must have access to GitHub-hosted ARM Linux runners for the `ubuntu-22.04-arm` job.

The workflow uploads this artifact:

```text
custom-vulkan-sdk-linux-x86_64-aarch64.tar.gz
```

Inside the archive:

```text
custom-vulkan-sdk/
  common/
  linux-x86_64/
  linux-aarch64/
  setup-env.sh
```

## Manual native build on Ubuntu/Debian

On each native architecture machine or runner, install the build dependencies:

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  cmake ninja-build git python3 pkg-config file binutils \
  build-essential \
  libwayland-dev libx11-dev libx11-xcb-dev libxcb1-dev libxrandr-dev
```

On an `x86_64` machine:

```bash
scripts/build-sdk.sh x86_64
```

On an `aarch64` machine:

```bash
scripts/build-sdk.sh aarch64
```

Then merge both `dist/custom-vulkan-sdk` trees and package the result:

```bash
scripts/check-compat.sh

tar -C dist -czf custom-vulkan-sdk-linux-x86_64-aarch64.tar.gz custom-vulkan-sdk
```

Native builds on newer distros may produce binaries that require newer glibc than the GitHub Actions build.

## Pin Vulkan source versions

By default, the build uses `main` from the upstream Khronos repositories. For reproducible builds, set matching tags or commits:

```bash
VULKAN_HEADERS_REF=v1.4.309 \
VULKAN_LOADER_REF=v1.4.309 \
scripts/build-sdk.sh x86_64
```

The GitHub workflow exposes the same refs as manual workflow inputs.

## Use the SDK

Extract the archive on a Linux `x86_64` or `aarch64` machine and source the setup script:

```bash
tar -xzf custom-vulkan-sdk-linux-x86_64-aarch64.tar.gz
source custom-vulkan-sdk/setup-env.sh
```

The script sets `VULKAN_SDK`, `PATH`, `LD_LIBRARY_PATH`, `CPATH`, `CMAKE_PREFIX_PATH`, and `PKG_CONFIG_PATH` for the current machine architecture.

## Disable Linux WSI dependencies

If you need a more headless/minimal loader build, disable XCB, Xlib, Xrandr, and Wayland WSI support:

```bash
ENABLE_WSI=OFF scripts/build-sdk.sh x86_64
ENABLE_WSI=OFF scripts/build-sdk.sh aarch64
```

The GitHub workflow also has an `enable_wsi` manual input.
