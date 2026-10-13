#!/bin/bash
# Repeat the three-process draft lifecycle with isolated AppKit state.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
app=${1:-"$repo/build/blank_.app"}
app=$(cd "$(dirname "$app")" && pwd)/$(basename "$app")
iterations=${2:-1}
if [[ ! "$iterations" =~ ^[1-9][0-9]*$ ]]; then
    echo 'Usage: check-drafts.sh [app] [positive iteration count]' >&2; exit 2
fi
os_version=$(sw_vers -productVersion)
os_major=${os_version%%.*}
if [[ ! "$os_major" =~ ^[0-9]+$ ]] || (( 10#$os_major < 27 )); then
    echo "Draft checks require macOS 27 or newer (found $os_version)" >&2; exit 2
fi
temporary=$(mktemp -d /tmp/blank-draft-check.XXXXXX)
# File coordination may resolve /tmp to /private/tmp. Use one canonical path
# for the data root and native snapshots throughout each lifecycle.
temporary=$(cd "$temporary" && pwd -P)
trap 'rm -rf "$temporary"' EXIT
cd "$temporary"
for ((iteration=1; iteration<=iterations; iteration++)); do
    relocated="$temporary/lifecycle-$iteration/blank_.app"
    mkdir -p "$(dirname "$relocated")"
    ditto "$app" "$relocated"
    # Keep one identity across a lifecycle's relaunches, but never reuse its
    # native window registry with another sequence's fresh recovery directory.
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.blank.acceptance.drafts.$(uuidgen)" "$relocated/Contents/Info.plist"
    codesign --force --deep --sign - "$relocated"
    codesign --verify --deep --strict "$relocated"
    log="$temporary/lifecycle-$iteration.log"
    for phase in prepare verify disabled-verify; do
        if ! BLANK_DATA_DIR="$temporary/data-$iteration" env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH "$relocated/Contents/MacOS/blank_" "--draft-lifecycle-$phase" >> "$log" 2>&1; then
            cat "$log"; exit 1
        fi
    done
    if (( iterations == 1 )); then cat "$log"; fi
    echo "PASS: native draft lifecycle $iteration/$iterations (prepare, restore, restoration disabled)"
    rm -rf "$(dirname "$relocated")"
done
