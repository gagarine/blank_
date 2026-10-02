#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
npm run build --prefix frontend
cargo build --release --locked --manifest-path helper/Cargo.toml
go build -tags desktop,production -trimpath -o build/bin/blank_ ./cmd/blank_
mkdir -p build/bin/blank_.app/Contents/MacOS build/bin/blank_.app/Contents/Resources
cp build/bin/blank_ build/bin/blank_.app/Contents/MacOS/blank_
cp helper/target/release/writer-helper build/bin/blank_.app/Contents/MacOS/writer-helper
cp build/darwin/Info.plist build/bin/blank_.app/Contents/Info.plist
if [ -n "${WRITER_VERSION:-}" ]; then
  release_version="${WRITER_VERSION#v}"
  release_version="${release_version%%[-+]*}"
  if ! [[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Release tags must use vMAJOR.MINOR.PATCH (with an optional suffix)." >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $release_version" build/bin/blank_.app/Contents/Info.plist
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $release_version" build/bin/blank_.app/Contents/Info.plist
fi
codesign --force --deep --sign - build/bin/blank_.app
echo 'Built build/bin/blank_.app'
