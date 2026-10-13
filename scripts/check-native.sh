#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
mode=${1:-background}
configuration=${2:-release}
case "$mode" in background) host=BlankIntegrationChecks ;; ui) host=BlankUIChecks ;; *) echo 'Usage: check-native.sh background|ui [debug|release]' >&2; exit 2 ;; esac
portable=$(mktemp -d /tmp/blank-native-check.XXXXXX)
portable=$(cd "$portable" && pwd -P)
export BLANK_DATA_DIR="$portable/data"
export BLANK_PACKAGE_CACHE="$portable/packages"
export BLANK_VERIFICATION_STATE="$portable/state.plist"
mkdir -p "$BLANK_DATA_DIR" "$BLANK_PACKAGE_CACHE"
if [[ "$mode" == ui ]]; then
    app=/tmp/blank-resize-ui/blank_.app
    # Reuse the identity authorized for native computer-use verification.
    # Never replace a running fixture or quit a user's other document app.
    if pgrep -f '^/tmp/blank-resize-ui/blank_.app/Contents/MacOS/blank_' >/dev/null; then
        echo 'Quit the disposable blank-resize-ui fixture before running UI checks.' >&2; exit 2
    fi
    identifier=local.blank.resize-ui
else
    app="$portable/Relocated app/blank_.app"
    identifier="local.blank.acceptance.background.$(uuidgen)"
fi
finish() {
    result=$?
    if [[ -f "$BLANK_VERIFICATION_STATE" ]]; then
        env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH "$app/Contents/MacOS/blank_" --restore-state || true
    fi
    rm -rf "$portable"
    return "$result"
}
trap finish EXIT
mkdir -p "$(dirname "$app")"
ditto "$repo/build/blank_.app" "$app"
cp "$repo/.build/$configuration/$host" "$app/Contents/MacOS/blank_.next"
mv "$app/Contents/MacOS/blank_.next" "$app/Contents/MacOS/blank_"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $identifier" "$app/Contents/Info.plist"
dependency=$(otool -L "$app/Contents/MacOS/blank_" | sed -n 's/^[[:space:]]*\(.*libblank_syntax\.dylib\) (compatibility.*$/\1/p')
test -n "$dependency"
install_name_tool -change "$dependency" @rpath/libblank_syntax.dylib "$app/Contents/MacOS/blank_"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
cd "$portable"
run() {
    env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH "$app/Contents/MacOS/blank_" "$@"
}
if [[ "$mode" == background ]]; then
    run
    export BLANK_DATA_DIR="$portable/draft-data"
    mkdir -p "$BLANK_DATA_DIR"
    for phase in prepare verify disabled-verify; do run "--draft-integration-$phase"; done
else
    echo 'Running explicit interactive UI checks; the disposable test app will take focus.'
    for suite in selection-style find paragraph-space template; do
        export BLANK_DATA_DIR="$portable/$suite-data"; mkdir -p "$BLANK_DATA_DIR"
        run "--$suite-self-test"
    done
    export BLANK_DATA_DIR="$portable/editing-data"; mkdir -p "$BLANK_DATA_DIR"
    run --self-test
    export BLANK_DATA_DIR="$portable/draft-data"; mkdir -p "$BLANK_DATA_DIR"
    for phase in prepare verify disabled-verify; do run "--draft-lifecycle-$phase"; done
fi
