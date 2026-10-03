#!/usr/bin/env bash
if [[ -n "${BASH_VERSION:-}" ]]; then
  WRITER_ENV_FILE="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
  WRITER_ENV_FILE="${(%):-%x}"
else
  echo "Source scripts/env.sh from Bash or Zsh." >&2
  return 1
fi
WRITER_ROOT="$(cd "$(dirname "$WRITER_ENV_FILE")/.." && pwd)"
if [[ -x "$WRITER_ROOT/.tools/cargo/bin/cargo" ]]; then
  export PATH="$WRITER_ROOT/.tools/cargo/bin:$PATH"
  export CARGO_HOME="$WRITER_ROOT/.tools/cargo" RUSTUP_HOME="$WRITER_ROOT/.tools/rustup"
fi
unset WRITER_ENV_FILE
