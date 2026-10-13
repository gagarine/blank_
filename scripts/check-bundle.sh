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
# Compiler/PDF protocol verification is headless and uses disposable data.
# Native integration and explicit UI hosts are packaged separately by check-native.
cd "$portable"
env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH python3 "$repo/scripts/compiler-check.py" "$relocated"
printf 'PASS: relocated app bundle (parser and compiler; no activation or keyboard events)\n'
