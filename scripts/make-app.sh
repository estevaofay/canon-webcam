#!/bin/bash
# Builds dist/canon-webcam.app (the menu bar app) and, with --dmg,
# dist/canon-webcam-VERSION.dmg. Run from anywhere: `make app` / `make dmg`.
#
# The app links one non-system library, libusb, which is copied into
# Contents/Frameworks so the app runs without Homebrew. Signed ad hoc only:
# the first launch needs System Settings → Privacy & Security → Open Anyway.
set -euo pipefail

cd "$(dirname "$0")/.."
version=$(tr -d '[:space:]' < VERSION)
dist=dist
app=$dist/canon-webcam.app
dmg=$dist/canon-webcam-$version.dmg
make_dmg=false
[[ ${1:-} == --dmg ]] && make_dmg=true

echo "==> building canon-webcam-app $version (release)"
swift build -c release --product canon-webcam-app
binary=$(swift build -c release --show-bin-path)/canon-webcam-app

echo "==> assembling $app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/canon-webcam"
sed "s/__VERSION__/$version/g" App/Info.plist > "$app/Contents/Info.plist"
plutil -lint -s "$app/Contents/Info.plist"

# libusb: find where the binary looks for it rather than assuming Homebrew's path.
exe=$app/Contents/MacOS/canon-webcam
libusb=$(otool -L "$exe" | awk '/libusb-1\.0/ { print $1; exit }')
[[ -n $libusb ]] || { echo "error: the app doesn't link libusb" >&2; exit 1; }
bundled=$app/Contents/Frameworks/libusb-1.0.0.dylib
cp "$(realpath "$libusb")" "$bundled"
chmod u+w "$bundled"
install_name_tool -id @rpath/libusb-1.0.0.dylib "$bundled" 2>/dev/null
# libusb is LGPL-2.1: ship its license, and say which version and where its source is.
libusb_home=$(cd "$(dirname "$(realpath "$libusb")")/.." && pwd)
cp "$libusb_home/COPYING" "$app/Contents/Resources/libusb-COPYING.txt"
libusb_version=$(basename "$libusb_home")
printf 'canon-webcam bundles libusb %s (LGPL-2.1, see libusb-COPYING.txt), unmodified,\nas Contents/Frameworks/libusb-1.0.0.dylib, which you may replace.\nSource: https://github.com/libusb/libusb/releases/tag/v%s\n' \
    "$libusb_version" "$libusb_version" > "$app/Contents/Resources/THIRD-PARTY-NOTICES.txt"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
install_name_tool -change "$libusb" @executable_path/../Frameworks/libusb-1.0.0.dylib "$exe" 2>/dev/null

# The toolchain adds a search path into this Mac's Xcode; the app mustn't look there.
otool -l "$exe" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' | while read -r rpath; do
    case $rpath in /usr/lib/*|@*) ;; *) install_name_tool -delete_rpath "$rpath" "$exe" 2>/dev/null ;; esac
done

for file in "$exe" "$bundled"; do
    if otool -L "$file" | tail -n +2 | grep -q /opt/homebrew; then
        echo "error: $file still links something from Homebrew:" >&2
        otool -L "$file" >&2
        exit 1
    fi
done

echo "==> drawing the icon"
iconset=.build/AppIcon.iconset
rm -rf "$iconset" && mkdir -p "$iconset"
swift scripts/make-icon.swift .build/icon_1024.png
for points in 16 32 128 256 512; do
    sips -z $points $points .build/icon_1024.png --out "$iconset/icon_${points}x${points}.png" >/dev/null
    double=$((points * 2))
    sips -z $double $double .build/icon_1024.png --out "$iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

echo "==> signing (ad hoc)"
codesign --force --sign - "$bundled"
codesign --force --sign - --identifier io.github.estevaofay.canon-webcam "$app"
codesign --verify --deep --strict "$app"
echo "$app"

if $make_dmg; then
    echo "==> packaging $dmg"
    staging=.build/dmg
    rm -rf "$staging" && mkdir -p "$staging"
    cp -R "$app" "$staging/"
    ln -s /Applications "$staging/Applications"
    hdiutil create -volname canon-webcam -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
    echo "$dmg"
fi
