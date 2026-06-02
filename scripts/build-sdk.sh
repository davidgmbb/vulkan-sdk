#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build-sdk.sh <x86_64|aarch64>

Build a minimal custom Vulkan SDK install tree under dist/custom-vulkan-sdk.
The script builds Vulkan-Headers once into common/ and Vulkan-Loader for the
requested Linux architecture into linux-<arch>/.

Environment variables:
  VULKAN_HEADERS_REF   Git ref for KhronosGroup/Vulkan-Headers (default: main)
  VULKAN_LOADER_REF    Git ref for KhronosGroup/Vulkan-Loader  (default: main)
  ENABLE_WSI           ON/OFF for XCB, Xlib, Xrandr and Wayland loader support (default: ON)
  WORK_DIR             Build/source directory (default: .build)
  DIST_DIR             Output directory (default: dist)
  JOBS                 Parallel build jobs (default: nproc)
USAGE
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

arch=${1:-}
if [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]]; then
  usage >&2
  exit 2
fi

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=${WORK_DIR:-"$root_dir/.build"}
dist_dir=${DIST_DIR:-"$root_dir/dist"}
src_dir="$work_dir/src"
build_dir="$work_dir/build"
sdk_dir="$dist_dir/custom-vulkan-sdk"
common_prefix="$sdk_dir/common"
arch_prefix="$sdk_dir/linux-$arch"
jobs=${JOBS:-$(nproc)}
headers_ref=${VULKAN_HEADERS_REF:-main}
loader_ref=${VULKAN_LOADER_REF:-main}
enable_wsi=${ENABLE_WSI:-ON}
host_arch=$(uname -m)
case "$host_arch" in
  arm64) host_arch=aarch64 ;;
esac

case "$enable_wsi" in
  ON|On|on|TRUE|True|true|1|YES|Yes|yes) enable_wsi=ON ;;
  OFF|Off|off|FALSE|False|false|0|NO|No|no) enable_wsi=OFF ;;
  *) echo "ENABLE_WSI must be ON or OFF, got: $enable_wsi" >&2; exit 2 ;;
esac

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

link_common_files() {
  ln -sfn ../common/include "$arch_prefix/include"
  mkdir -p "$arch_prefix/share/vulkan"
  ln -sfn ../../../common/share/vulkan/registry "$arch_prefix/share/vulkan/registry"
}

write_setup_env() {
  cat > "$sdk_dir/setup-env.sh" <<'EOF'
#!/usr/bin/env bash
# Source this file: source /path/to/custom-vulkan-sdk/setup-env.sh

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This script must be sourced, not executed." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$(uname -m)" in
  x86_64) ARCH=linux-x86_64 ;;
  aarch64|arm64) ARCH=linux-aarch64 ;;
  *) echo "Unsupported machine architecture: $(uname -m)" >&2; return 1 ;;
esac

export VULKAN_SDK="$ROOT/$ARCH"
export PATH="$VULKAN_SDK/bin:${PATH:-}"
export LD_LIBRARY_PATH="$VULKAN_SDK/lib:${LD_LIBRARY_PATH:-}"
export CPATH="$ROOT/common/include:${CPATH:-}"
export CMAKE_PREFIX_PATH="$VULKAN_SDK:$ROOT/common:${CMAKE_PREFIX_PATH:-}"
export PKG_CONFIG_PATH="$VULKAN_SDK/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
EOF
  chmod +x "$sdk_dir/setup-env.sh"
}

echo "==> Fetching Vulkan sources"
clone_ref https://github.com/KhronosGroup/Vulkan-Headers.git "$headers_ref" "$src_dir/Vulkan-Headers"
clone_ref https://github.com/KhronosGroup/Vulkan-Loader.git "$loader_ref" "$src_dir/Vulkan-Loader"

write_setup_env

echo "==> Building Vulkan-Headers ($headers_ref)"
cmake -S "$src_dir/Vulkan-Headers" -B "$build_dir/headers" -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$common_prefix"
cmake --build "$build_dir/headers" --target install --parallel "$jobs"
link_common_files

loader_cmake_args=(
  -S "$src_dir/Vulkan-Loader"
  -B "$build_dir/loader-$arch"
  -GNinja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$arch_prefix"
  -DCMAKE_PREFIX_PATH="$common_prefix"
  -DVULKAN_HEADERS_INSTALL_DIR="$common_prefix"
  -DBUILD_TESTS=OFF
  -DBUILD_WSI_XCB_SUPPORT="$enable_wsi"
  -DBUILD_WSI_XLIB_SUPPORT="$enable_wsi"
  -DBUILD_WSI_XLIB_XRANDR_SUPPORT="$enable_wsi"
  -DBUILD_WSI_WAYLAND_SUPPORT="$enable_wsi"
  -DBUILD_WSI_DIRECTFB_SUPPORT=OFF
)

if [[ "$arch" == "aarch64" && "$host_arch" != "aarch64" ]]; then
  echo "==> Cross-compiling aarch64 from $host_arch"
  export PKG_CONFIG_LIBDIR="/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
  export PKG_CONFIG_PATH=""
  export PKG_CONFIG_SYSROOT_DIR=""
  loader_cmake_args+=(
    -DCMAKE_TOOLCHAIN_FILE="$root_dir/cmake/toolchains/aarch64-linux-gnu.cmake"
  )
elif [[ "$arch" != "$host_arch" ]]; then
  echo "Cannot build linux-$arch on host architecture $host_arch without a toolchain." >&2
  exit 2
else
  echo "==> Native build on $host_arch"
fi

echo "==> Building Vulkan-Loader ($loader_ref) for linux-$arch, WSI=$enable_wsi"
cmake "${loader_cmake_args[@]}"
cmake --build "$build_dir/loader-$arch" --target install --parallel "$jobs"

echo "==> Installed linux-$arch files under $arch_prefix"
find "$arch_prefix" -maxdepth 2 -type f | sort
