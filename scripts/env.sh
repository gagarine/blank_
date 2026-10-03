#!/usr/bin/env bash
WRITER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$WRITER_ROOT/.tools/cargo/bin:$PATH"
export CARGO_HOME="$WRITER_ROOT/.tools/cargo" RUSTUP_HOME="$WRITER_ROOT/.tools/rustup"
