#!/bin/bash
set -euo pipefail
app=$1
sdk_path=$2
version=$3
repo=$(cd "$(dirname "$0")/.." && pwd)
frameworks="$app/Contents/Frameworks"
mkdir -p "$frameworks"
cp "$repo/target/release/libblank_container.dylib" "$frameworks/libblank_container.dylib.next"
mv "$frameworks/libblank_container.dylib.next" "$frameworks/libblank_container.dylib"
if codesign -d "$frameworks/libblank_container.dylib" >/dev/null 2>&1; then codesign --remove-signature "$frameworks/libblank_container.dylib"; fi
install_name_tool -id @rpath/libblank_container.dylib "$frameworks/libblank_container.dylib"
codesign --force --sign - "$frameworks/libblank_container.dylib"
for kind in Preview Thumbnail; do
    extension="$app/Contents/PlugIns/Blank$kind.appex"
    mkdir -p "$extension/Contents/MacOS"
    xcrun swiftc -sdk "$sdk_path" -module-cache-path "$repo/.build/module-cache" -target arm64-apple-macos27.0 -O -parse-as-library -application-extension \
        -module-name "Blank$kind" -Xlinker -e -Xlinker _NSExtensionMain \
        -I "$repo/Sources/CContainer" -L "$repo/target/release" -lblank_container \
        -Xlinker -rpath -Xlinker @executable_path/../../../../Frameworks \
        "$repo/Sources/BlankQuickLook/StoredPreview.swift" "$repo/Sources/BlankQuickLook/${kind}Provider.swift" \
        -o "$extension/Contents/MacOS/Blank$kind.next"
    mv "$extension/Contents/MacOS/Blank$kind.next" "$extension/Contents/MacOS/Blank$kind"
    dependency=$(otool -L "$extension/Contents/MacOS/Blank$kind" | sed -n 's/^[[:space:]]*\(.*libblank_container\.dylib\) (compatibility.*$/\1/p')
    test -n "$dependency"
    codesign --remove-signature "$extension/Contents/MacOS/Blank$kind"
    install_name_tool -change "$dependency" @rpath/libblank_container.dylib "$extension/Contents/MacOS/Blank$kind"
    python3 - "$extension/Contents/Info.plist" "$kind" "$version" <<'PY'
import plistlib,sys
path,kind,version=sys.argv[1:]
attributes={'QLSupportedContentTypes':['org.typst.project-container']}
if kind=='Preview': attributes['QLIsDataBasedPreview']=True
else: attributes['QLThumbnailMinimumDimension']=64
info={'CFBundleIdentifier':'local.blank.swift-native.'+kind.lower(),
      'CFBundleName':'Blank'+kind,'CFBundleDisplayName':'blank_ '+kind,
      'CFBundleExecutable':'Blank'+kind,'CFBundlePackageType':'XPC!',
      'CFBundleVersion':version,'CFBundleShortVersionString':version,
      'LSMinimumSystemVersion':'27.0',
      'NSExtension':{'NSExtensionPointIdentifier':'com.apple.quicklook.'+kind.lower(),
                     'NSExtensionPrincipalClass':'Blank'+kind+'Provider',
                     'NSExtensionAttributes':attributes}}
with open(path,'wb') as f: plistlib.dump(info,f)
PY
    codesign --force --sign - --entitlements "$repo/Resources/QuickLook.entitlements" "$extension"
done
