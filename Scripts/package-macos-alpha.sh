#!/bin/bash
# Package an already built/tested universal app; never sign with a personal key.
set -euo pipefail

readonly SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# != 3 || ! "$3" =~ ^[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
  echo "Usage: bash Scripts/package-macos-alpha.sh BUILD_DIR OUTPUT_DIR VERSION-alpha.N" >&2
  exit 2
fi
readonly BUILD_DIR="$(cd "$1" && pwd)"
mkdir -p "$2"
readonly OUTPUT_DIR="$(cd "$2" && pwd)"
readonly VERSION="$3"
readonly SDK_ROOT="${XMEETING_H323PLUS_ROOT:-$SOURCE_ROOT/.build/h323plus/macos-universal}"
readonly APP="$BUILD_DIR/XMeeting.app"
readonly NAME="XMeeting-$VERSION-macos-universal"
readonly SOURCE_NAME="XMeeting-$VERSION-source"

if [[ -n "$(git -C "$SOURCE_ROOT" status --porcelain --untracked-files=normal)" ]]; then
  echo "Release packaging requires a clean committed checkout (source must match binary)." >&2
  exit 1
fi
for asset in "$NAME.zip" "$SOURCE_NAME.tar.gz" SHA256SUMS.txt; do
  if [[ -e "$OUTPUT_DIR/$asset" ]]; then
    echo "Refusing to overwrite release asset: $OUTPUT_DIR/$asset" >&2
    exit 1
  fi
done
lipo "$APP/Contents/MacOS/XMeeting" -verify_arch x86_64 arm64
codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "${VERSION%%-alpha.*}"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" = 11.0
# Verify the actual executable, not just the minimum OS written in Info.plist.
for architecture in x86_64 arm64; do
  test "$(xcrun vtool -arch "$architecture" -show-build "$APP/Contents/MacOS/XMeeting" | \
           awk '$1 == "minos" { print $2 }')" = 11.0
  # This app links third-party code statically; only Apple/system dylibs belong here.
  if otool -arch "$architecture" -L "$APP/Contents/MacOS/XMeeting" | tail -n +2 | \
     awk '{ print $1 }' | grep -Ev '^(/usr/lib/|/System/Library/|$)' ; then
    echo "Unexpected non-system dynamic dependency in release app ($architecture)." >&2
    exit 1
  fi
done
for input in Versions.txt sources/ptlib-v2_10_9_6.tar.gz sources/h323plus-v1_28_0.tar.gz \
             licenses/PTLib-MPL-1.0.html licenses/H323Plus-MPL-1.0.html licenses/H323Plus-MPL-1.1.html; do
  test -s "$SDK_ROOT/$input"
done

readonly STAGING="$(mktemp -d "${TMPDIR:-/tmp}/xmeeting-package.XXXXXX")"
# Only this script's fresh, explicitly named temporary directory is removed.
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/$NAME/Licenses" "$STAGING/$SOURCE_NAME"
ditto "$APP" "$STAGING/$NAME/XMeeting.app"
cp "$SOURCE_ROOT/Documentation/AlphaTesting.md" "$STAGING/$NAME/START-HERE.md"
cp "$SOURCE_ROOT/Documentation/ThirdPartyNotices.md" "$STAGING/$NAME/Licenses/"
cp "$SOURCE_ROOT/COPYING" "$STAGING/$NAME/Licenses/XMeeting.txt"
cp "$SDK_ROOT"/licenses/*.html "$STAGING/$NAME/Licenses/"
cp "$SDK_ROOT/Versions.txt" "$STAGING/$NAME/Dependencies.txt"
{
  printf 'Version=%s\nCommit=%s\n' "$VERSION" "$(git -C "$SOURCE_ROOT" rev-parse HEAD)"
  printf 'Signing=ad-hoc; NOT Developer ID signed or notarized\n'
  printf 'MinimumOS=macOS 11.0\nArchitectures=x86_64 arm64\n'
} > "$STAGING/$NAME/Build.txt"
git -C "$SOURCE_ROOT" archive HEAD | tar -x -C "$STAGING/$SOURCE_NAME"
mkdir -p "$STAGING/$SOURCE_NAME/Dependencies/upstream-sources"
cp "$SDK_ROOT"/sources/*.tar.gz "$STAGING/$SOURCE_NAME/Dependencies/upstream-sources/"
cp "$STAGING/$NAME/Build.txt" "$STAGING/$SOURCE_NAME/Build.txt"
cp "$SDK_ROOT/Versions.txt" "$STAGING/$SOURCE_NAME/Dependencies/Versions.txt"
ditto -c -k --sequesterRsrc --keepParent "$STAGING/$NAME" "$OUTPUT_DIR/$NAME.zip"
COPYFILE_DISABLE=1 tar -czf "$OUTPUT_DIR/$SOURCE_NAME.tar.gz" -C "$STAGING" "$SOURCE_NAME"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$NAME.zip" "$SOURCE_NAME.tar.gz" > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)
echo "Packaged $OUTPUT_DIR/$NAME.zip (experimental, not notarized)."
