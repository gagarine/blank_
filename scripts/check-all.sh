#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=${1:-release}
bash scripts/check.sh "$configuration"
# The background suite already built and packaged the verification hosts.
bash scripts/check-native.sh ui "$configuration"
