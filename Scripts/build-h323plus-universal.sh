#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly PTLIB_REPOSITORY="https://github.com/willamowius/ptlib.git"
readonly PTLIB_TAG="v2_10_9_6"
readonly H323PLUS_REPOSITORY="https://github.com/willamowius/h323plus.git"
readonly H323PLUS_TAG="v1_28_0"
readonly DEPLOYMENT_TARGET="${XMEETING_DEPLOYMENT_TARGET:-14.0}"
readonly ARCHITECTURES="${XMEETING_ARCHITECTURES:-x86_64 arm64}"
readonly WORK_ROOT="${XMEETING_H323PLUS_WORK_ROOT:-$SOURCE_ROOT/.build/h323plus/work}"
readonly OUTPUT_ROOT="${XMEETING_H323PLUS_OUTPUT_ROOT:-$SOURCE_ROOT/.build/h323plus/macos-universal}"
readonly SOURCE_CACHE="$WORK_ROOT/sources"
readonly PATCH_FILE="$SOURCE_ROOT/Dependencies/patches/ptlib-2.10.9.6-apple-silicon.patch"

if [[ "$WORK_ROOT" == "/" || -z "$WORK_ROOT" || "$OUTPUT_ROOT" == "/" || -z "$OUTPUT_ROOT" ]]; then
  echo "Refusing to use an unsafe build or output directory." >&2
  exit 2
fi

for required_tool in awk git make patch tar lipo xcrun; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    echo "Required tool is missing: $required_tool" >&2
    exit 2
  fi
done

readonly SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
readonly CLANG="$(xcrun --sdk macosx --find clang)"
readonly CLANGXX="$(xcrun --sdk macosx --find clang++)"
readonly AR_TOOL="$(xcrun --sdk macosx --find ar)"
readonly RANLIB_TOOL="$(xcrun --sdk macosx --find ranlib)"

detect_build_jobs() {
  local jobs=""
  if jobs="$(sysctl -n hw.ncpu 2>/dev/null)"; then
    :
  elif jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null)"; then
    :
  fi

  if [[ ! "$jobs" =~ ^[1-9][0-9]*$ ]]; then
    jobs=4
  fi
  printf '%s\n' "$jobs"
}

readonly BUILD_JOBS="${XMEETING_BUILD_JOBS:-$(detect_build_jobs)}"

mkdir -p "$SOURCE_CACHE" "$WORK_ROOT/architectures"

fetch_source() {
  local repository="$1"
  local tag="$2"
  local destination="$3"

  if [[ -d "$destination/.git" ]]; then
    return
  fi

  git clone --depth 1 --branch "$tag" "$repository" "$destination"
}

reset_architecture_directory() {
  local directory="$1"
  case "$directory" in
    "$WORK_ROOT"/architectures/*) ;;
    *)
      echo "Refusing to reset unexpected directory: $directory" >&2
      exit 2
      ;;
  esac

  rm -rf "$directory"
  mkdir -p "$directory"
}

extract_source() {
  local repository="$1"
  local tag="$2"
  local destination="$3"

  mkdir -p "$destination"
  git -C "$repository" archive "$tag" | tar -x -C "$destination"
}

host_triplet_for_architecture() {
  case "$1" in
    x86_64) echo "x86_64-apple-darwin" ;;
    arm64) echo "aarch64-apple-darwin" ;;
    *)
      echo "Unsupported architecture: $1" >&2
      exit 2
      ;;
  esac
}

normalise_ptlib_build_options() {
  local header="$1"
  local temporary_header="$header.xmeeting"

  # Apple's Intel ABI has an extended-precision long double while arm64's
  # long double is the same width as double. Autoconf consequently emits
  # architecture-specific headers, which cannot be shipped in one SDK. Keep
  # the distinction, but express it with compiler architecture macros.
  awk '
    /^#define PNO_LONG_DOUBLE/ || /^\/\* #undef PNO_LONG_DOUBLE \*\// {
      print "#if defined(__aarch64__) || defined(__arm64__)"
      print "#  define PNO_LONG_DOUBLE 1"
      print "#endif"
      next
    }
    { print }
  ' "$header" > "$temporary_header"
  mv "$temporary_header" "$header"
}

fetch_source "$PTLIB_REPOSITORY" "$PTLIB_TAG" "$SOURCE_CACHE/ptlib"
fetch_source "$H323PLUS_REPOSITORY" "$H323PLUS_TAG" "$SOURCE_CACHE/h323plus"

readonly BUILD_TRIPLET="$(sh "$SOURCE_CACHE/ptlib/config.guess")"
ptlib_archives=()
h323plus_archives=()
header_source=""

for architecture in $ARCHITECTURES; do
  architecture_root="$WORK_ROOT/architectures/$architecture"
  ptlib_source="$architecture_root/ptlib"
  h323plus_source="$architecture_root/h323plus"
  stage_root="$architecture_root/stage"
  common_flags="-arch $architecture -isysroot $SDK_PATH -mmacosx-version-min=$DEPLOYMENT_TARGET -fno-common"
  host_triplet="$(host_triplet_for_architecture "$architecture")"

  echo "Building PTLib $PTLIB_TAG for $architecture"
  reset_architecture_directory "$architecture_root"
  extract_source "$SOURCE_CACHE/ptlib" "$PTLIB_TAG" "$ptlib_source"
  extract_source "$SOURCE_CACHE/h323plus" "$H323PLUS_TAG" "$h323plus_source"
  patch -d "$ptlib_source" -p1 < "$PATCH_FILE"

  (
    cd "$ptlib_source"
    env \
      CC="$CLANG" \
      CXX="$CLANGXX" \
      CFLAGS="$common_flags" \
      CXXFLAGS="$common_flags -std=c++17" \
      LDFLAGS="$common_flags" \
      MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
      ./configure \
        --build="$BUILD_TRIPLET" \
        --host="$host_triplet" \
        --prefix="$stage_root" \
        --libdir="$OUTPUT_ROOT/lib" \
        --disable-expat \
        --disable-lua \
        --disable-odbc \
        --disable-openldap \
        --disable-openssl \
        --disable-sasl \
        --disable-sdl \
        --enable-audio \
        --enable-ipv6 \
        --enable-plugins \
        --enable-video

    normalise_ptlib_build_options "$ptlib_source/include/ptbuildopts.h"

    make -j"$BUILD_JOBS" optnoshared \
      AR="$AR_TOOL" \
      CC="$CLANG" \
      CXX="$CLANGXX" \
      LD="$CLANGXX" \
      RANLIB="$RANLIB_TOOL" \
      CFLAGS="$common_flags" \
      STDCXXFLAGS="-std=c++17" \
      LDFLAGS="$common_flags"
  )

  echo "Building H323Plus $H323PLUS_TAG for $architecture"
  (
    cd "$h323plus_source"
    env \
      CC="$CLANG" \
      CXX="$CLANGXX" \
      CFLAGS="$common_flags" \
      CXXFLAGS="$common_flags -std=c++17" \
      LDFLAGS="$common_flags" \
      MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
      PTLIBDIR="$ptlib_source" \
      ./configure \
        --build="$BUILD_TRIPLET" \
        --host="$host_triplet" \
        --prefix="$stage_root" \
        --disable-h235 \
        --disable-h235-256

    make -j"$BUILD_JOBS" optnoshared \
      AR="$AR_TOOL" \
      CC="$CLANG" \
      CXX="$CLANGXX" \
      LD="$CLANGXX" \
      RANLIB="$RANLIB_TOOL" \
      CFLAGS="$common_flags" \
      STDCXXFLAGS="-std=c++17" \
      LDFLAGS="$common_flags"
  )

  ptlib_archive="$ptlib_source/lib_Darwin_aarch64/libpt_s.a"
  if [[ "$architecture" == "x86_64" ]]; then
    ptlib_archive="$ptlib_source/lib_Darwin_x86_64/libpt_s.a"
  fi
  h323plus_archive="$(find "$h323plus_source/lib" -maxdepth 1 -name 'libh323_*_s.a' -print -quit)"

  if [[ ! -f "$ptlib_archive" || ! -f "$h323plus_archive" ]]; then
    echo "Expected static libraries were not produced for $architecture." >&2
    exit 1
  fi

  ptlib_archives+=("$ptlib_archive")
  h323plus_archives+=("$h323plus_archive")
  if [[ -z "$header_source" ]]; then
    header_source="$architecture_root"
  else
    cmp "$header_source/ptlib/include/ptbuildopts.h" "$ptlib_source/include/ptbuildopts.h"
    cmp "$header_source/h323plus/include/openh323buildopts.h" "$h323plus_source/include/openh323buildopts.h"
  fi
done

staging_output="$WORK_ROOT/universal-output"
rm -rf "$staging_output"
mkdir -p "$staging_output/include" "$staging_output/lib"

cp "$header_source/ptlib/include/ptlib.h" "$header_source/ptlib/include/ptbuildopts.h" "$staging_output/include/"
cp -R "$header_source/ptlib/include/ptlib" "$header_source/ptlib/include/ptclib" "$staging_output/include/"
cp -R "$header_source/h323plus/include" "$staging_output/include/openh323"

lipo -create "${ptlib_archives[@]}" -output "$staging_output/lib/libptlib.a"
lipo -create "${h323plus_archives[@]}" -output "$staging_output/lib/libh323plus.a"

{
  printf 'PTLib=%s\n' "$PTLIB_TAG"
  printf 'H323Plus=%s\n' "$H323PLUS_TAG"
  printf 'DeploymentTarget=%s\n' "$DEPLOYMENT_TARGET"
  printf 'Architectures=%s\n' "$ARCHITECTURES"
} > "$staging_output/Versions.txt"

rm -rf "$OUTPUT_ROOT"
mkdir -p "$(dirname "$OUTPUT_ROOT")"
mv "$staging_output" "$OUTPUT_ROOT"

echo "Created universal H323Plus SDK at $OUTPUT_ROOT"
lipo -info "$OUTPUT_ROOT/lib/libptlib.a"
lipo -info "$OUTPUT_ROOT/lib/libh323plus.a"
