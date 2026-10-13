#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=${1:-release}
export MACOSX_DEPLOYMENT_TARGET=27.0
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
# CLT 27 ships Testing but its default explicit-module scan misses this plugin.
# Use the plugin paired with the selected compiler, when it exists.
swift_binary=$(xcrun --find swiftc)
plugin="$(dirname "$swift_binary")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
options=()
if [[ -f "$plugin" ]]; then options+=(-Xswiftc -load-plugin-library -Xswiftc "$plugin"); fi
DYLD_LIBRARY_PATH="$PWD/target/release" swift test --disable-sandbox --cache-path .build/cache -c "$configuration" --sdk "${BLANK_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}" -Xswiftc -DBLANK_MACOS27_SDK "${options[@]}" --filter BlankUnitTests
