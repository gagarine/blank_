#!/bin/bash
set -euo pipefail
os_version=$(sw_vers -productVersion)
os_major=${os_version%%.*}
if [[ ! "$os_major" =~ ^[0-9]+$ ]] || (( 10#$os_major < 27 )); then
    echo "Bundle checks require macOS 27 or newer (found $os_version)" >&2; exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
app=${1:-"$repo/build/blank_.app"}
portable=$(mktemp -d /tmp/blank-bundle-check.XXXXXX)
trap 'rm -rf "$portable"' EXIT
relocated="$portable/Relocated app/blank_.app"
ditto "$app" "$relocated"
codesign --verify --deep --strict "$relocated"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$relocated/Contents/Info.plist")" = 27.0
for binary in blank_ libblank_syntax.dylib typst-compiler; do
    lipo "$relocated/Contents/MacOS/$binary" -verify_arch arm64
    xcrun vtool -show-build "$relocated/Contents/MacOS/$binary" | awk '
        $1 == "minos" { seen = 1; split($2, version, "."); if (version[1] < 27) invalid = 1 }
        END { exit (!seen || invalid) }
    ' || { echo "Packaged $binary must target macOS 27 or newer" >&2; exit 1; }
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
# Foreground/pointer checks have app-wide focus and event-queue effects. Keep
# their full assertions in a separate process and disposable recovery directory.
BLANK_DATA_DIR="$portable/selection-style-data" env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH "$relocated/Contents/MacOS/blank_" --selection-style-self-test
# The complete Find lifecycle uses its own windows and native focus transitions.
BLANK_DATA_DIR="$portable/find-data" env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH "$relocated/Contents/MacOS/blank_" --find-self-test
# Citation Space uses its own foreground keyboard/window fixture and mock API.
BLANK_DATA_DIR="$portable/paragraph-space-data" env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH "$relocated/Contents/MacOS/blank_" --paragraph-space-self-test
BLANK_DATA_DIR="$portable/data" env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH "$relocated/Contents/MacOS/blank_" --self-test
# Lifecycle relaunches use independent native window state and recovery data.
bash "$repo/scripts/check-drafts.sh" "$relocated"
printf 'PASS: relocated app bundle (in-process parser and separate compiler)\n'
