#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_ROOT="$PWD"
mkdir -p .tools
if [ ! -x .tools/go/bin/go ]; then
  curl -fLsS https://go.dev/dl/go1.27.1.darwin-arm64.tar.gz -o .tools/go.tar.gz
  echo 'ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12  .tools/go.tar.gz' | shasum -a 256 -c -
  tar -xzf .tools/go.tar.gz -C .tools
  rm .tools/go.tar.gz
fi
export CARGO_HOME="$TASK_ROOT/.tools/cargo" RUSTUP_HOME="$TASK_ROOT/.tools/rustup"
if [ ! -x "$CARGO_HOME/bin/rustc" ]; then
  curl -fLsS https://sh.rustup.rs -o .tools/rustup-init.sh
  sh .tools/rustup-init.sh -y --no-modify-path --profile minimal --default-toolchain 1.98.1
fi

source scripts/env.sh
npm ci --prefix frontend
go mod download
cargo fetch --locked --manifest-path helper/Cargo.toml
