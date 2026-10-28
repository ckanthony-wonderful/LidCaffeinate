#!/usr/bin/env bash
# Build LidCaffeinate.app into ./build (ad-hoc signed).
#   ./build.sh             build for this Mac
#   ./build.sh --install   build, copy to /Applications (replacing an older copy) and launch
#   ./build.sh --release   universal build (Apple Silicon + Intel), zipped to build/LidCaffeinate.zip
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-}"
APP=build/LidCaffeinate.app
FLAGS=(-O -swift-version 5 -framework AppKit -framework IOKit -framework ServiceManagement)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "$MODE" = "--release" ]; then
  for arch in arm64 x86_64; do
    swiftc "${FLAGS[@]}" -target "$arch-apple-macos13.0" main.swift -o "build/LidCaffeinate-$arch"
  done
  lipo -create build/LidCaffeinate-arm64 build/LidCaffeinate-x86_64 -output "$APP/Contents/MacOS/LidCaffeinate"
  rm -f build/LidCaffeinate-arm64 build/LidCaffeinate-x86_64
else
  swiftc "${FLAGS[@]}" -target "$(uname -m)-apple-macos13.0" main.swift -o "$APP/Contents/MacOS/LidCaffeinate"
fi
cp Info.plist "$APP/Contents/Info.plist"
# app icon (regenerate with: swift icon/make_icon.swift icon && iconutil -c icns icon/AppIcon.iconset -o icon/AppIcon.icns)
[ -f icon/AppIcon.icns ] && cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "built $APP"
if [ "$MODE" = "--release" ]; then
  rm -f build/LidCaffeinate.zip
  ditto -c -k --keepParent "$APP" build/LidCaffeinate.zip
  echo "zipped build/LidCaffeinate.zip"
fi
if [ "$MODE" = "--install" ]; then
  osascript -e 'tell application id "com.anthony.lidcaffeinate" to quit' 2>/dev/null || true
  sleep 1
  rm -rf /Applications/LidCaffeinate.app
  cp -R "$APP" /Applications/
  open /Applications/LidCaffeinate.app
  echo "installed to /Applications and launched"
fi
