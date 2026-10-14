#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cd "$(pwd -P)"
configuration=${1:-release}
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
os_version=$(sw_vers -productVersion)
os_major=${os_version%%.*}
if [[ ! "$os_major" =~ ^[0-9]+$ ]] || (( 10#$os_major < 27 )); then
    echo "Checks require macOS 27 or newer (found $os_version)" >&2; exit 2
fi
export BLANK_SDK_PATH=${BLANK_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}
sdk_version=$(/usr/libexec/PlistBuddy -c 'Print :Version' "$BLANK_SDK_PATH/SDKSettings.plist")
sdk_major=${sdk_version%%.*}
if [[ ! "$sdk_major" =~ ^[0-9]+$ ]] || (( 10#$sdk_major < 27 )); then
    echo "Checks require a macOS 27 or newer SDK (found $sdk_version at $BLANK_SDK_PATH)" >&2; exit 2
fi
export MACOSX_DEPLOYMENT_TARGET=27.0
# Swift linking and app packaging use this shared workspace output directory.
export CARGO_TARGET_DIR="$PWD/target"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
export BLANK_BUILD_CHECKS=1
checks_temporary=$(mktemp -d /tmp/blank-background-check.XXXXXX)
checks_temporary=$(cd "$checks_temporary" && pwd -P)
trap 'rm -rf "$checks_temporary"' EXIT
export BLANK_DATA_DIR="$checks_temporary/data"
export BLANK_PACKAGE_CACHE="$checks_temporary/packages"
mkdir -p "$BLANK_DATA_DIR" "$BLANK_PACKAGE_CACHE"
cargo fmt --check --package blank-syntax
cargo_options=(--locked)
if [[ "${BLANK_OFFLINE:-0}" == 1 ]]; then cargo_options+=(--offline); fi
cargo test --workspace --release "${cargo_options[@]}"
bash scripts/build.sh "$configuration"
bash scripts/check-unit.sh "$configuration"
bash scripts/check-bundle.sh
bash scripts/check-native.sh background "$configuration"
