#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
go build -o build/bin/blank_ .
exec build/bin/blank_ serve "$@"
