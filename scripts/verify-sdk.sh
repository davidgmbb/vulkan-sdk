#!/usr/bin/env bash
set -euo pipefail

sdk_dir=${1:-dist/custom-vulkan-sdk}
platform=${2:-}
arch=${3:-}
max_glibc=${MAX_GLIBC_VERSION:-}
require_slang=${BUILD_SLANG:-ON}
case "$require_slang" in
  ON|On|on|TRUE|True|true|1|YES|Yes|yes) require_slang=ON ;;
  OFF|Off|off|FALSE|False|false|0|NO|No|no) require_slang=OFF ;;
  *) echo "BUILD_SLANG must be ON or OFF, got: $require_slang" >&2; exit 2 ;;
esac

usage() {
  echo "Usage: scripts/verify-sdk.sh [sdk-dir] <linux|windows|macos> <x86_64|aarch64>" >&2
}

if [[ -z "$platform" || -z "$arch" ]]; then
  usage
  exit 2
fi

case "$platform" in
  linux|windows|macos) ;;
  *) usage; exit 2 ;;
esac
case "$arch" in
  x86_64|aarch64) ;;
  *) usage; exit 2 ;;
esac

prefix="$sdk_dir/$platform-$arch"
if [[ ! -d "$prefix" ]]; then
  echo "SDK prefix does not exist: $prefix" >&2
  exit 1
fi

require_file() {
  local path=$1
  if [[ ! -e "$path" ]]; then
    echo "Missing expected file: $path" >&2
    exit 1
  fi
}

version_gt() {
  local a=$1
  local b=$2
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" == "$a" && "$a" != "$b" ]]
}

check_glibc_floor() {
  local file=$1
  [[ -n "$max_glibc" ]] || return 0
  command -v readelf >/dev/null 2>&1 || return 0

  local status=0
  local versions
  versions=$(readelf --version-info "$file" 2>/dev/null | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sed 's/^GLIBC_//' | sort -Vu || true)
  while IFS= read -r version; do
    [[ -z "$version" ]] && continue
    if version_gt "$version" "$max_glibc"; then
      echo "ERROR: $file requires GLIBC_$version, newer than baseline GLIBC_$max_glibc" >&2
      status=1
    fi
  done <<< "$versions"
  return "$status"
}

check_file_type() {
  local path=$1
  local expected=$2
  command -v file >/dev/null 2>&1 || return 0
  echo "==> $path"
  file -L "$path"
  file -L "$path" | grep -Eq "$expected"
}

case "$platform" in
  linux)
    require_file "$prefix/lib/libvulkan.so"
    case "$arch" in
      x86_64) check_file_type "$prefix/lib/libvulkan.so" 'x86-64' ;;
      aarch64) check_file_type "$prefix/lib/libvulkan.so" 'ARM aarch64' ;;
    esac
    while IFS= read -r -d '' elf; do
      check_glibc_floor "$elf"
    done < <(find "$prefix" -type f \( -name '*.so' -o -name '*.so.*' \) -print0)
    ;;
  macos)
    require_file "$prefix/lib/libvulkan.dylib"
    case "$arch" in
      x86_64) check_file_type "$prefix/lib/libvulkan.dylib" 'x86_64' ;;
      aarch64) check_file_type "$prefix/lib/libvulkan.dylib" 'arm64|aarch64' ;;
    esac
    ;;
  windows)
    require_file "$prefix/lib/vulkan-1.lib"
    require_file "$prefix/bin/vulkan-1.dll"
    ;;
esac

if [[ "$require_slang" == ON ]]; then
  if [[ -f "$prefix/bin/slangc" ]]; then
    "$prefix/bin/slangc" -version || true
  elif [[ -f "$prefix/bin/slangc.exe" ]]; then
    "$prefix/bin/slangc.exe" -version || true
  else
    echo "Missing slangc. Set BUILD_SLANG=OFF only if this is intentional." >&2
    exit 1
  fi
fi

echo "SDK verification passed for $platform-$arch."
