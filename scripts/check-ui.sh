#!/bin/bash
# Explicitly interactive: never called by check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=${1:-release}
export BLANK_BUILD_CHECKS=1
bash scripts/build.sh "$configuration"
bash scripts/check-native.sh ui "$configuration"
