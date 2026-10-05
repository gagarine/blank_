#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=${1:-release}
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
export MACOSX_DEPLOYMENT_TARGET=26.0
# Swift linking and app packaging use this shared workspace output directory.
export CARGO_TARGET_DIR="$PWD/target"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
cargo fmt --check --package blank-syntax
cargo_options=(--locked)
if [[ "${BLANK_OFFLINE:-0}" == 1 ]]; then cargo_options+=(--offline); fi
cargo test --workspace --release "${cargo_options[@]}"
bash scripts/build.sh "$configuration"
DYLD_LIBRARY_PATH="$PWD/target/release" ".build/$configuration/BlankCoreChecks"
bash scripts/check-bundle.sh
