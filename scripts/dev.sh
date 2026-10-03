#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
cargo build --release --locked -p writer-helper
export BLANK_HELPER="$PWD/target/release/writer-helper"
exec cargo run --locked -p blank-native -- "$@"
