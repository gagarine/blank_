#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
npm run build --prefix frontend
cargo build --release --manifest-path helper/Cargo.toml
go build -tags desktop,production -trimpath -o build/bin/blank_ .
mkdir -p build/bin/blank_.app/Contents/MacOS build/bin/blank_.app/Contents/Resources
cp build/bin/blank_ build/bin/blank_.app/Contents/MacOS/blank_
cp helper/target/release/writer-helper build/bin/blank_.app/Contents/MacOS/writer-helper
cp build/darwin/Info.plist build/bin/blank_.app/Contents/Info.plist
codesign --force --deep --sign - build/bin/blank_.app
echo 'Built build/bin/blank_.app'
