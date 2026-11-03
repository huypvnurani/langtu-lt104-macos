#!/bin/zsh
# Build YuhKeyScreen.app vào dist/. Thêm --install để copy vào /Applications.
set -euo pipefail
cd "$(dirname "$0")"

# Universal: chạy cả Apple Silicon lẫn Intel.
swift build -c release --arch arm64 --arch x86_64
APP=dist/YuhKeyScreen.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/YuhKeyScreen "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"

# Icon: vẽ từ tools/make-icon.swift, cache lại ở Resources/AppIcon.icns.
if [[ ! -f Resources/AppIcon.icns || tools/make-icon.swift -nt Resources/AppIcon.icns ]]; then
  TMP=$(mktemp -d)
  swift tools/make-icon.swift "$TMP/icon.png"
  mkdir -p "$TMP/AppIcon.iconset" Resources
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/solutions.urani.YuhKeyScreen.sync.plist "$APP/Contents/Library/LaunchAgents/"
codesign --force --sign - "$APP"
echo "Built $APP"

# File zip để đính kèm GitHub Release.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ditto -c -k --keepParent "$APP" "dist/YuhKeyScreen-$VERSION.zip"
echo "Packed dist/YuhKeyScreen-$VERSION.zip"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x YuhKeyScreen 2>/dev/null || true
  while pgrep -x YuhKeyScreen >/dev/null; do sleep 0.2; done
  rm -rf /Applications/YuhKeyScreen.app
  cp -R "$APP" /Applications/
  open /Applications/YuhKeyScreen.app
  echo "Installed /Applications/YuhKeyScreen.app"
fi
