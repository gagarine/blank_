#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
cargo build --release --locked -p writer-helper
native_profile="release"
if [[ "${1:-}" == "--debug" ]]; then
  native_profile="debug"
  cargo build --locked -p blank_
else
  cargo build --release --locked -p blank_
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  if [[ "$native_profile" != "release" ]]; then
    cp target/release/writer-helper "target/$native_profile/writer-helper"
  fi
  echo "Built target/$native_profile/blank_"
  exit 0
fi
native_bundle="build/bin/blank_.app"
mkdir -p "$native_bundle/Contents/MacOS"
cp "target/$native_profile/blank_" "$native_bundle/Contents/MacOS/blank_"
cp target/release/writer-helper "$native_bundle/Contents/MacOS/writer-helper"
cat > "$native_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>blank_</string>
<key>CFBundleDisplayName</key><string>blank_</string>
<key>CFBundleIdentifier</key><string>local.still.writer.rust-prototype</string>
<key>CFBundleExecutable</key><string>blank_</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
if [[ -n "${WRITER_VERSION:-}" ]]; then
  release_version="${WRITER_VERSION#v}"
  release_version="${release_version%%[-+]*}"
  if ! [[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Release tags must use vMAJOR.MINOR.PATCH (with an optional suffix)." >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $release_version" "$native_bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $release_version" "$native_bundle/Contents/Info.plist"
fi
codesign --force --sign - "$native_bundle/Contents/MacOS/writer-helper"
codesign --force --sign - "$native_bundle"
echo "Built $native_bundle"
