#!/usr/bin/env bash
# Build Presenter.app — a native macOS launcher for the decks in ~/Documents/presentations.
# No npm, no Electron. Just swiftc.
set -euo pipefail
cd "$(dirname "$0")"

APP="Presenter.app"
BIN="$APP/Contents/MacOS/Presenter"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Presenter</string>
  <key>CFBundleDisplayName</key>       <string>Presenter</string>
  <key>CFBundleIdentifier</key>        <string>fi.oneira.presenter</string>
  <key>CFBundleExecutable</key>        <string>Presenter</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>NSHumanReadableCopyright</key>  <string>Copyright © 2026 Oscar Neira. MIT licensed.</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "compiling…"
swiftc -O -parse-as-library \
  -target arm64-apple-macosx13.0 \
  -framework SwiftUI -framework WebKit -framework AppKit \
  -o "$BIN" Presenter.swift

# a simple blue icon so it is findable in the Dock
if command -v sips >/dev/null 2>&1; then
  ICON_SRC=".icon.png"
  python3 - "$ICON_SRC" <<'PY' 2>/dev/null || true
import sys, struct, zlib
w = h = 512
px = bytearray()
for y in range(h):
    px.append(0)
    for x in range(w):
        # rounded blue square on transparent
        m = 56
        inside = (m <= x < w-m) and (m <= y < h-m)
        r = 64
        cx = min(max(x, m+r), w-m-r); cy = min(max(y, m+r), h-m-r)
        if inside and ((x-cx)**2 + (y-cy)**2) > r*r and (abs(x-cx) > 0 and abs(y-cy) > 0):
            inside = False
        px += bytes((26,105,255,255)) if inside else bytes((0,0,0,0))
def chunk(t, d):
    c = t + d
    return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(bytes(px), 9))
       + chunk(b'IEND', b''))
open(sys.argv[1], 'wb').write(png)
PY
  if [ -f "$ICON_SRC" ]; then
    ICONSET=".AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for s in 16 32 64 128 256 512; do
      sips -z $s $s "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1 || true
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1 || true
    rm -rf "$ICONSET" "$ICON_SRC"
  fi
fi

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP"

echo
echo "Built $(pwd)/$APP"
echo
echo "Open it:            open '$(pwd)/$APP'"
echo "Keep it in the Dock: drag it there once, then it is one click forever."
echo "Install to /Applications:  cp -R '$APP' /Applications/"
