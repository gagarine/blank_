#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=${1:-release}
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
export MACOSX_DEPLOYMENT_TARGET=26.0
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
cargo fmt --check --manifest-path typst-syntax-bridge/Cargo.toml
cargo_options=(--locked)
if [[ "${BLANK_OFFLINE:-0}" == 1 ]]; then cargo_options+=(--offline); fi
cargo test "${cargo_options[@]}" --manifest-path typst-syntax-bridge/Cargo.toml
bash scripts/build.sh "$configuration"
DYLD_LIBRARY_PATH="$PWD/typst-syntax-bridge/target/release" ".build/$configuration/BlankCoreChecks"
python3 scripts/compiler-check.py
acceptance_data=$(mktemp -d /tmp/blank-native-acceptance.XXXXXX)
trap 'rm -rf "$acceptance_data"' EXIT
BLANK_DATA_DIR="$acceptance_data" build/blank_.app/Contents/MacOS/blank_ --self-test
