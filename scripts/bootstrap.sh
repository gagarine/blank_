#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_ROOT="$PWD"
mkdir -p .tools
export CARGO_HOME="$TASK_ROOT/.tools/cargo" RUSTUP_HOME="$TASK_ROOT/.tools/rustup"
if [[ ! -x "$CARGO_HOME/bin/rustup" ]]; then
  curl -fLsS https://sh.rustup.rs -o .tools/rustup-init.sh
  sh .tools/rustup-init.sh -y --no-modify-path --profile minimal --default-toolchain stable
fi
source scripts/env.sh
rustup toolchain install stable --profile minimal --component rustfmt --component clippy
cargo fetch --locked
