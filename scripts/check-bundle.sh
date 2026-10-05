#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
app=${1:-"$repo/build/blank_.app"}
portable=$(mktemp -d /tmp/blank-bundle-check.XXXXXX)
trap 'rm -rf "$portable"' EXIT
relocated="$portable/Relocated app/blank_.app"
ditto "$app" "$relocated"
codesign --verify --deep --strict "$relocated"
for binary in blank_ libblank_syntax.dylib typst-compiler; do
    lipo "$relocated/Contents/MacOS/$binary" -verify_arch arm64
done
test ! -e "$relocated/Contents/MacOS/writer-helper"
otool -L "$relocated/Contents/MacOS/blank_" | grep -q '@rpath/libblank_syntax.dylib'
# Keep AppKit's draft/restoration registry and preferences separate from the
# user's app. A unique test identity also prevents reopening a crashed test.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.blank.acceptance.$(uuidgen)" "$relocated/Contents/Info.plist"
codesign --force --deep --sign - "$relocated"
codesign --verify --deep --strict "$relocated"
# Launch away from the checkout, without development library search paths.
# Native acceptance also exercises Swift's bundled compiler lookup and PDF export.
cd "$portable"
env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH python3 "$repo/scripts/compiler-check.py" "$relocated"
BLANK_DATA_DIR="$portable/data" env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH "$relocated/Contents/MacOS/blank_" --self-test
printf 'PASS: relocated app bundle (in-process parser and separate compiler)\n'
