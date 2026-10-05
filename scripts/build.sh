#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=${1:-debug}
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
app_version=${BLANK_VERSION:-0.2.0}
app_version=${app_version#v}
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]]; then
    echo 'BLANK_VERSION must be X.Y.Z or vX.Y.Z, optionally with a prerelease/build suffix' >&2; exit 2
fi
app_version=${app_version%%[-+]*}
export MACOSX_DEPLOYMENT_TARGET=26.0
# Swift linking and app packaging use this shared workspace output directory.
export CARGO_TARGET_DIR="$PWD/target"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" .build/cache
cargo_options=(--locked)
if [[ "${BLANK_OFFLINE:-0}" == 1 ]]; then cargo_options+=(--offline); fi
cargo build --workspace --release "${cargo_options[@]}"
sdk_path=${BLANK_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}
sdk_version=$(/usr/libexec/PlistBuddy -c 'Print :Version' "$sdk_path/SDKSettings.plist")
swift_options=(--sdk "$sdk_path")
if (( ${sdk_version%%.*} >= 27 )); then swift_options+=(-Xswiftc -DBLANK_MACOS27_SDK); fi
swift build --disable-sandbox --cache-path .build/cache -c "$configuration" "${swift_options[@]}"
app="$PWD/build/blank_.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install_binary() {
    cp "$1" "$2.next"
    mv "$2.next" "$2"
}
# Replacing an inode keeps a running editor's signed executable pages intact.
# Writing over its executable can make macOS terminate the running process.
install_binary ".build/$configuration/blank_" "$app/Contents/MacOS/blank_"
install_binary target/release/libblank_syntax.dylib "$app/Contents/MacOS/libblank_syntax.dylib"
install_binary target/release/typst-compiler "$app/Contents/MacOS/typst-compiler"
# Remove the previous compiler name when rebuilding an existing bundle.
rm -f "$app/Contents/MacOS/writer-helper"
cp examples/Tutorial.typ Resources/AppIcon.icns "$app/Contents/Resources/"
install_name_tool -id @rpath/libblank_syntax.dylib "$app/Contents/MacOS/libblank_syntax.dylib"
parser_dependency=$(otool -L "$app/Contents/MacOS/blank_" | sed -n 's/^[[:space:]]*\(.*libblank_syntax\.dylib\) (compatibility.*$/\1/p')
if [[ -z "$parser_dependency" ]]; then echo 'Missing Typst parser dependency in editor executable' >&2; exit 1; fi
install_name_tool -change "$parser_dependency" @rpath/libblank_syntax.dylib "$app/Contents/MacOS/blank_"
otool -L "$app/Contents/MacOS/blank_" | grep -q '@rpath/libblank_syntax.dylib'
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>blank_</string>
<key>CFBundleDisplayName</key><string>blank_</string>
<key>CFBundleIdentifier</key><string>local.blank.swift-native</string>
<key>CFBundleExecutable</key><string>blank_</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>UTImportedTypeDeclarations</key><array><dict><key>UTTypeIdentifier</key><string>org.typst.source</string><key>UTTypeDescription</key><string>Typst document</string><key>UTTypeConformsTo</key><array><string>public.plain-text</string></array><key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>typ</string></array><key>public.mime-type</key><string>text/x-typst</string></dict></dict></array>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Typst document</string><key>CFBundleTypeRole</key><string>Editor</string><key>NSDocumentClass</key><string>BlankDocument</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>org.typst.source</string></array></dict></array>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $app_version" "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
# Refresh the bundle's Finder date only after packaging succeeds.
touch "$app"
