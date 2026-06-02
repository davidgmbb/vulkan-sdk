#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build-sdk.sh [linux|windows|macos] <x86_64|aarch64>
       scripts/build-sdk.sh <x86_64|aarch64>   # backwards-compatible Linux form

Build a minimal custom Vulkan SDK install tree under dist/custom-vulkan-sdk.
The script builds Vulkan-Headers once into common/ and Vulkan-Loader for the
requested platform/architecture into <platform>-<arch>/.

Environment variables:
  VULKAN_HEADERS_REF   Git ref for KhronosGroup/Vulkan-Headers (default: main)
  VULKAN_LOADER_REF    Git ref for KhronosGroup/Vulkan-Loader  (default: main)
  SLANG_REF            Git ref for shader-slang/slang (default: master)
  BUILD_SLANG          ON/OFF to include slangc and Slang libraries (default: ON)
  SLANG_LLVM_FLAVOR    Slang LLVM mode; DISABLE avoids extra binary downloads (default: DISABLE)
  SLANG_ENABLE_DXIL    ON/OFF for Slang DXIL support (default: OFF)
  ENABLE_WSI           Linux only: ON/OFF for XCB, Xlib, Xrandr and Wayland support (default: ON)
  WORK_DIR             Build/source directory (default: .build)
  DIST_DIR             Output directory (default: dist)
  JOBS                 Parallel build jobs (default: nproc/sysctl/2)
USAGE
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -eq 1 ]]; then
  platform=linux
  arch=$1
elif [[ $# -eq 2 ]]; then
  platform=$1
  arch=$2
else
  usage >&2
  exit 2
fi

case "$platform" in
  linux|Linux) platform=linux ;;
  windows|Windows|win32|Win32) platform=windows ;;
  macos|MacOS|darwin|Darwin) platform=macos ;;
  *) usage >&2; exit 2 ;;
esac

case "$arch" in
  x86_64|amd64|AMD64) arch=x86_64 ;;
  aarch64|arm64|ARM64) arch=aarch64 ;;
  *) usage >&2; exit 2 ;;
esac

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=${WORK_DIR:-"$root_dir/.build"}
dist_dir=${DIST_DIR:-"$root_dir/dist"}
src_dir="$work_dir/src"
build_dir="$work_dir/build"
sdk_dir="$dist_dir/custom-vulkan-sdk"
common_prefix="$sdk_dir/common"
arch_prefix="$sdk_dir/$platform-$arch"

if command -v nproc >/dev/null 2>&1; then
  default_jobs=$(nproc)
elif command -v sysctl >/dev/null 2>&1; then
  default_jobs=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
else
  default_jobs=2
fi
jobs=${JOBS:-$default_jobs}

headers_ref=${VULKAN_HEADERS_REF:-main}
loader_ref=${VULKAN_LOADER_REF:-main}
slang_ref=${SLANG_REF:-master}
build_slang=${BUILD_SLANG:-ON}
slang_llvm_flavor=${SLANG_LLVM_FLAVOR:-DISABLE}
slang_enable_dxil=${SLANG_ENABLE_DXIL:-OFF}
enable_wsi=${ENABLE_WSI:-ON}
host_arch=$(uname -m)
case "$host_arch" in
  arm64) host_arch=aarch64 ;;
  amd64|AMD64) host_arch=x86_64 ;;
esac
host_os=$(uname -s)

normalize_bool() {
  local name=$1
  local value=$2
  case "$value" in
    ON|On|on|TRUE|True|true|1|YES|Yes|yes) echo ON ;;
    OFF|Off|off|FALSE|False|false|0|NO|No|no) echo OFF ;;
    *) echo "$name must be ON or OFF, got: $value" >&2; return 2 ;;
  esac
}

enable_wsi=$(normalize_bool ENABLE_WSI "$enable_wsi")
build_slang=$(normalize_bool BUILD_SLANG "$build_slang")
slang_enable_dxil=$(normalize_bool SLANG_ENABLE_DXIL "$slang_enable_dxil")

mkdir -p "$src_dir" "$build_dir" "$common_prefix" "$arch_prefix"

clone_ref() {
  local repo_url=$1
  local ref=$2
  local dest=$3

  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" fetch --depth 1 origin "$ref" || git -C "$dest" fetch origin "$ref"
    git -C "$dest" checkout --detach FETCH_HEAD
    return
  fi

  if ! git clone --depth 1 --branch "$ref" "$repo_url" "$dest"; then
    rm -rf "$dest"
    git clone "$repo_url" "$dest"
    git -C "$dest" checkout "$ref"
  fi
}

clone_slang() {
  local ref=$1
  local dest=$2

  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" fetch origin "$ref" || true
    git -C "$dest" fetch --tags --force origin || true
    git -C "$dest" checkout "$ref" || git -C "$dest" checkout --detach FETCH_HEAD
    git -C "$dest" submodule update --init --recursive --depth 1
    return
  fi

  if ! git clone --recursive --depth 1 --branch "$ref" https://github.com/shader-slang/slang.git "$dest"; then
    rm -rf "$dest"
    git clone --recursive https://github.com/shader-slang/slang.git "$dest"
    git -C "$dest" checkout "$ref"
    git -C "$dest" submodule update --init --recursive
  fi
  git -C "$dest" fetch --tags --force origin || true
}

copy_common_files() {
  rm -rf "$arch_prefix/include" "$arch_prefix/share/vulkan/registry"
  mkdir -p "$arch_prefix/share/vulkan"
  cp -a "$common_prefix/include" "$arch_prefix/include"
  if [[ -d "$common_prefix/share/vulkan/registry" ]]; then
    cp -a "$common_prefix/share/vulkan/registry" "$arch_prefix/share/vulkan/registry"
  fi
}

write_setup_env_sh() {
  cat > "$sdk_dir/setup-env.sh" <<'EOF'
#!/usr/bin/env bash
# Source this file: source /path/to/custom-vulkan-sdk/setup-env.sh

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This script must be sourced, not executed." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$(uname -s)" in
  Linux*) PLATFORM=linux ;;
  Darwin*) PLATFORM=macos ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
  *) echo "Unsupported OS: $(uname -s)" >&2; return 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *) echo "Unsupported machine architecture: $(uname -m)" >&2; return 1 ;;
esac

export VULKAN_SDK="$ROOT/$PLATFORM-$ARCH"
export PATH="$VULKAN_SDK/bin:${PATH:-}"
export CPATH="$VULKAN_SDK/include:$ROOT/common/include:${CPATH:-}"
export CMAKE_PREFIX_PATH="$VULKAN_SDK:$ROOT/common:${CMAKE_PREFIX_PATH:-}"
export PKG_CONFIG_PATH="$VULKAN_SDK/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

case "$PLATFORM" in
  linux) export LD_LIBRARY_PATH="$VULKAN_SDK/lib:${LD_LIBRARY_PATH:-}" ;;
  macos) export DYLD_LIBRARY_PATH="$VULKAN_SDK/lib:${DYLD_LIBRARY_PATH:-}" ;;
esac
EOF
  chmod +x "$sdk_dir/setup-env.sh"
}

write_setup_env_ps1() {
  cat > "$sdk_dir/setup-env.ps1" <<'EOF'
# Source this file from PowerShell:
#   . .\custom-vulkan-sdk\setup-env.ps1

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Machine = $env:PROCESSOR_ARCHITECTURE
switch -Regex ($Machine) {
  '^(AMD64|x86_64)$' { $Arch = 'x86_64'; break }
  '^(ARM64|aarch64)$' { $Arch = 'aarch64'; break }
  default { throw "Unsupported machine architecture: $Machine" }
}

$env:VULKAN_SDK = Join-Path $Root "windows-$Arch"
$env:Path = (Join-Path $env:VULKAN_SDK 'bin') + [IO.Path]::PathSeparator + $env:Path
$env:CPATH = (Join-Path $env:VULKAN_SDK 'include') + [IO.Path]::PathSeparator + (Join-Path $Root 'common\include') + [IO.Path]::PathSeparator + $env:CPATH
$env:CMAKE_PREFIX_PATH = $env:VULKAN_SDK + [IO.Path]::PathSeparator + (Join-Path $Root 'common') + [IO.Path]::PathSeparator + $env:CMAKE_PREFIX_PATH
EOF
}

cmake_generator_args=()
cmake_configure_type_args=()
cmake_build_config_args=()

if [[ "$platform" == "windows" ]]; then
  cmake_generator_args=(-G "Visual Studio 17 2022")
  if [[ "$arch" == "x86_64" ]]; then
    cmake_generator_args+=(-A x64)
  else
    cmake_generator_args+=(-A ARM64)
  fi
  cmake_build_config_args=(--config Release)
else
  cmake_generator_args=(-G Ninja)
  cmake_configure_type_args=(-DCMAKE_BUILD_TYPE=Release)
fi

loader_extra_args=()
if [[ "$platform" == "linux" ]]; then
  loader_extra_args+=(
    -DBUILD_WSI_XCB_SUPPORT="$enable_wsi"
    -DBUILD_WSI_XLIB_SUPPORT="$enable_wsi"
    -DBUILD_WSI_XLIB_XRANDR_SUPPORT="$enable_wsi"
    -DBUILD_WSI_WAYLAND_SUPPORT="$enable_wsi"
    -DBUILD_WSI_DIRECTFB_SUPPORT=OFF
  )

  if [[ "$arch" == "aarch64" && "$host_arch" != "aarch64" ]]; then
    echo "==> Cross-compiling linux-aarch64 from $host_arch"
    export PKG_CONFIG_LIBDIR="/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
    export PKG_CONFIG_PATH=""
    export PKG_CONFIG_SYSROOT_DIR=""
    loader_extra_args+=(
      -DCMAKE_TOOLCHAIN_FILE="$root_dir/cmake/toolchains/aarch64-linux-gnu.cmake"
    )
  elif [[ "$arch" != "$host_arch" ]]; then
    echo "Cannot build linux-$arch on host architecture $host_arch without a toolchain." >&2
    exit 2
  else
    echo "==> Native Linux build on $host_arch"
  fi
elif [[ "$platform" == "macos" ]]; then
  if [[ "$host_os" != Darwin* ]]; then
    echo "Cannot build macos-$arch on non-macOS host $host_os." >&2
    exit 2
  fi
  if [[ "$arch" != "$host_arch" ]]; then
    echo "Cannot build macos-$arch on host architecture $host_arch with this script." >&2
    exit 2
  fi
  echo "==> Native macOS build on $host_arch"
elif [[ "$platform" == "windows" ]]; then
  case "$host_os" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) echo "Cannot build windows-$arch on non-Windows host $host_os." >&2; exit 2 ;;
  esac
  echo "==> Native Windows build requested for $arch"
fi

echo "==> Fetching Vulkan sources"
clone_ref https://github.com/KhronosGroup/Vulkan-Headers.git "$headers_ref" "$src_dir/Vulkan-Headers"
clone_ref https://github.com/KhronosGroup/Vulkan-Loader.git "$loader_ref" "$src_dir/Vulkan-Loader"
if [[ "$build_slang" == ON ]]; then
  echo "==> Fetching Slang sources"
  clone_slang "$slang_ref" "$src_dir/slang"
fi

write_setup_env_sh
write_setup_env_ps1

echo "==> Building Vulkan-Headers ($headers_ref)"
cmake -S "$src_dir/Vulkan-Headers" -B "$build_dir/headers-$platform-$arch" \
  "${cmake_generator_args[@]}" \
  "${cmake_configure_type_args[@]}" \
  -DCMAKE_INSTALL_PREFIX="$common_prefix"
cmake --build "$build_dir/headers-$platform-$arch" --target install --parallel "$jobs" "${cmake_build_config_args[@]}"
copy_common_files

loader_cmake_args=(
  -S "$src_dir/Vulkan-Loader"
  -B "$build_dir/loader-$platform-$arch"
  "${cmake_generator_args[@]}"
  "${cmake_configure_type_args[@]}"
  -DCMAKE_INSTALL_PREFIX="$arch_prefix"
  -DCMAKE_PREFIX_PATH="$common_prefix"
  -DVULKAN_HEADERS_INSTALL_DIR="$common_prefix"
  -DBUILD_TESTS=OFF
  "${loader_extra_args[@]}"
)

echo "==> Building Vulkan-Loader ($loader_ref) for $platform-$arch"
cmake "${loader_cmake_args[@]}"
cmake --build "$build_dir/loader-$platform-$arch" --target install --parallel "$jobs" "${cmake_build_config_args[@]}"

if [[ "$build_slang" == ON ]]; then
  slang_cmake_args=(
    -S "$src_dir/slang"
    -B "$build_dir/slang-$platform-$arch"
    "${cmake_generator_args[@]}"
    "${cmake_configure_type_args[@]}"
    -DCMAKE_INSTALL_PREFIX="$arch_prefix"
    -DSLANG_ENABLE_SLANGC=ON
    -DSLANG_ENABLE_SLANGD=OFF
    -DSLANG_ENABLE_SLANGI=OFF
    -DSLANG_ENABLE_SLANGRT=ON
    -DSLANG_ENABLE_TESTS=OFF
    -DSLANG_ENABLE_EXAMPLES=OFF
    -DSLANG_ENABLE_GFX=OFF
    -DSLANG_ENABLE_SLANG_RHI=OFF
    -DSLANG_ENABLE_REPLAYER=OFF
    -DSLANG_ENABLE_DXIL="$slang_enable_dxil"
    -DSLANG_SLANG_LLVM_FLAVOR="$slang_llvm_flavor"
    -DSLANG_ENABLE_RELEASE_LTO=OFF
  )

  echo "==> Building Slang ($slang_ref) for $platform-$arch"
  cmake "${slang_cmake_args[@]}"
  cmake --build "$build_dir/slang-$platform-$arch" --target install --parallel "$jobs" "${cmake_build_config_args[@]}"
fi

echo "==> Installed $platform-$arch files under $arch_prefix"
find "$arch_prefix" -maxdepth 3 -type f | sort
