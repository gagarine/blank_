#!/bin/bash
set -euo pipefail
os_version=$(sw_vers -productVersion)
os_major=${os_version%%.*}
if [[ ! "$os_major" =~ ^[0-9]+$ ]] || (( 10#$os_major < 27 )); then
    echo "Bundle checks require macOS 27 or newer (found $os_version)" >&2; exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
app=${1:-"$repo/build/blank_.app"}
portable=$(mktemp -d /tmp/blank-bundle-check.XXXXXX)
trap 'rm -rf "$portable"' EXIT
relocated="$portable/Relocated app/blank_.app"
ditto "$app" "$relocated"
codesign --verify --deep --strict "$relocated"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$relocated/Contents/Info.plist")" = 27.0
for binary in blank_ libblank_syntax.dylib typst-compiler; do
    lipo "$relocated/Contents/MacOS/$binary" -verify_arch arm64
    xcrun vtool -show-build "$relocated/Contents/MacOS/$binary" | awk '
        $1 == "minos" { seen = 1; split($2, version, "."); if (version[1] < 27) invalid = 1 }
        END { exit (!seen || invalid) }
    ' || { echo "Packaged $binary must target macOS 27 or newer" >&2; exit 1; }
done
test ! -e "$relocated/Contents/MacOS/writer-helper"
python3 - "$relocated" <<'PY'
import ctypes,pathlib,plistlib,subprocess,sys,zipfile
app=pathlib.Path(sys.argv[1])
library=app/'Contents/Frameworks/libblank_container.dylib'
subprocess.run(['lipo',str(library),'-verify_arch','arm64'],check=True)
with (app/'Contents/Info.plist').open('rb') as f: info=plistlib.load(f)
container=next(t for t in info['UTImportedTypeDeclarations'] if t['UTTypeIdentifier']=='org.typst.project-container')
assert 'public.zip-archive' not in container['UTTypeConformsTo']
assert container['UTTypeIcons']['UTTypeIconText']=='TYPZ'
for kind in ['Preview','Thumbnail']:
    extension=app/f'Contents/PlugIns/Blank{kind}.appex'
    with (extension/'Contents/Info.plist').open('rb') as f: metadata=plistlib.load(f)
    assert metadata['NSExtension']['NSExtensionAttributes']['QLSupportedContentTypes']==['org.typst.project-container']
    binary=extension/f'Contents/MacOS/Blank{kind}'
    subprocess.run(['lipo',str(binary),'-verify_arch','arm64'],check=True)
    linked=subprocess.check_output(['otool','-L',str(binary)],text=True)
    assert '@rpath/libblank_container.dylib' in linked
    assert '/Users/' not in linked
    result=subprocess.run(['codesign','-d','--entitlements',':-',str(extension)],capture_output=True,check=True)
    assert plistlib.loads(result.stdout)['com.apple.security.app-sandbox'] is True
# Exercise the exact cached-reader library from the relocated bundle. Deliberately
# invalid source proves that browsing needs no compiler or project extraction.
fixture=app.parent/'Saved preview.typz'
pdf=b'%PDF-1.7\nCached bytes'
with zipfile.ZipFile(fixture,'w') as archive:
    archive.comment=b"entrypoint = 'main.typ'\n[blank_]\nversion = 1\npreview = 'preview.pdf'\n"
    archive.writestr('main.typ','#invalid(')
    archive.writestr('preview.pdf',pdf)
reader=ctypes.CDLL(str(library))
reader.blank_container_preview.argtypes=[ctypes.c_char_p,ctypes.POINTER(ctypes.c_size_t)]
reader.blank_container_preview.restype=ctypes.c_void_p
reader.blank_container_free.argtypes=[ctypes.c_void_p,ctypes.c_size_t]
length=ctypes.c_size_t()
pointer=reader.blank_container_preview(bytes(fixture),ctypes.byref(length))
assert pointer
try: assert ctypes.string_at(pointer,length.value)==pdf
finally: reader.blank_container_free(pointer,length.value)
print('PASS: native document icon, sandboxed extensions and cached-reader library work after relocation')
PY
otool -L "$relocated/Contents/MacOS/blank_" | grep -q '@rpath/libblank_syntax.dylib'
# Compiler/PDF protocol verification is headless and uses disposable data.
# Native integration and explicit UI hosts are packaged separately by check-native.
cd "$portable"
env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH python3 "$repo/scripts/compiler-check.py" "$relocated"
printf 'PASS: relocated app bundle (parser and compiler; no activation or keyboard events)\n'
