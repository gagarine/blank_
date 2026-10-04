#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
cargo fmt --check --manifest-path typst-syntax-bridge/Cargo.toml
cargo test --offline --locked --manifest-path typst-syntax-bridge/Cargo.toml
swift run --disable-sandbox --cache-path .build/cache BlankCoreChecks
bash scripts/build.sh
BLANK_DATA_DIR="$(mktemp -d /tmp/blank-native-acceptance.XXXXXX)" build/blank_.app/Contents/MacOS/blank_ --self-test
