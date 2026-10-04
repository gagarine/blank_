#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" .build/cache
cargo build --offline --release --locked --manifest-path typst-syntax-bridge/Cargo.toml
cargo build --offline --release --locked --manifest-path helper/Cargo.toml
configuration=${1:-debug}
swift build --disable-sandbox --cache-path .build/cache -c "$configuration"
app="$PWD/build/blank_.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install_binary() {
    cp "$1" "$2.next"
    mv "$2.next" "$2"
}
# Replacing an inode keeps a running editor's signed executable pages intact.
# Writing over its executable can make macOS terminate the running process.
install_binary ".build/$configuration/blank_" "$app/Contents/MacOS/blank_"
install_binary typst-syntax-bridge/target/release/libblank_syntax.dylib "$app/Contents/MacOS/libblank_syntax.dylib"
install_binary helper/target/release/writer-helper "$app/Contents/MacOS/writer-helper"
cp examples/Tutorial.typ "$app/Contents/Resources/"
install_name_tool -id @rpath/libblank_syntax.dylib "$app/Contents/MacOS/libblank_syntax.dylib"
install_name_tool -change "$PWD/typst-syntax-bridge/target/release/libblank_syntax.dylib" @rpath/libblank_syntax.dylib "$app/Contents/MacOS/blank_"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>blank_</string>
<key>CFBundleDisplayName</key><string>blank_</string>
<key>CFBundleIdentifier</key><string>local.blank.swift-native</string>
<key>CFBundleExecutable</key><string>blank_</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>UTImportedTypeDeclarations</key><array><dict><key>UTTypeIdentifier</key><string>org.typst.source</string><key>UTTypeDescription</key><string>Typst document</string><key>UTTypeConformsTo</key><array><string>public.plain-text</string></array><key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>typ</string></array><key>public.mime-type</key><string>text/x-typst</string></dict></dict></array>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Typst document</string><key>CFBundleTypeRole</key><string>Editor</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>org.typst.source</string></array></dict></array>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
