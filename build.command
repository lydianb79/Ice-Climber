#!/bin/bash
# Builds the game app from your ROM: 6502 -> C static recompilation,
# then compiles a native universal (Apple Silicon + Intel) macOS app.
# Double-click this file in Finder, or run it in Terminal.
set -euo pipefail
cd "$(dirname "$0")"

source ./game.conf
ROM="${1:-$ROM_DEFAULT}"
APP="../$NAME.app"

echo "== $NAME recomp build =="
if ! xcode-select -p >/dev/null 2>&1; then
    echo "Apple's Command Line Tools are needed (free). Starting the installer..."
    xcode-select --install || true
    echo "Run this script again once the installation has finished."
    read -r -p "Press Return to close." _
    exit 1
fi
if [ ! -f "$ROM" ]; then
    echo "ROM not found at: $ROM"
    echo "Usage: ./build.command /path/to/rom.nes"
    exit 1
fi

echo "-> Recompiling 6502 code to C"
python3 recomp.py "$ROM" gen

ARCHS="-arch arm64 -arch x86_64"
echo "-> Compiling (universal: arm64 + x86_64)"
mkdir -p build
CFLAGS="-O2 -std=gnu11 -mmacosx-version-min=11.0 -Wno-unused-label -Wno-deprecated-declarations"
clang $CFLAGS $ARCHS -c gen/game_recomp.c -o build/game_recomp.o
clang $CFLAGS $ARCHS -c gen/game_rom.c    -o build/game_rom.o
for f in nes ppu apu; do clang $CFLAGS $ARCHS -c runtime/$f.c -o build/$f.o; done
clang $CFLAGS $ARCHS -fobjc-arc -c platform/mac/main.m -o build/main.o
clang $ARCHS -mmacosx-version-min=11.0 build/*.o -o "build/$NAME" \
    -framework Cocoa -framework QuartzCore -framework AudioToolbox -framework GameController

echo "-> Packaging app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/$NAME" "$APP/Contents/MacOS/$NAME"
sed -e "s/__NAME__/$NAME/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" platform/mac/Info.plist > "$APP/Contents/Info.plist"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s platform/mac/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d platform/mac/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "(icon step skipped)"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP"

echo ""
echo "Done: $(cd "$(dirname "$APP")" && pwd)/$NAME.app"
open -R "$APP" 2>/dev/null || true
