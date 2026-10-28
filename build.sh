#!/usr/bin/env bash
# Build LidCaffeinate.app into ./build (ad-hoc signed). Usage: ./build.sh [--install]
#   --install  copy to /Applications (replacing an older copy) and launch it
set -euo pipefail
cd "$(dirname "$0")"
APP=build/LidCaffeinate.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework IOKit -framework ServiceManagement \
  main.swift -o "$APP/Contents/MacOS/LidCaffeinate"
cp Info.plist "$APP/Contents/Info.plist"
# app icon (regenerate with: swift icon/make_icon.swift icon && iconutil -c icns icon/AppIcon.iconset -o icon/AppIcon.icns)
[ -f icon/AppIcon.icns ] && cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "built $APP"
if [ "${1:-}" = "--install" ]; then
  osascript -e 'tell application id "com.anthony.lidcaffeinate" to quit' 2>/dev/null || true
  sleep 1
  rm -rf /Applications/LidCaffeinate.app
  cp -R "$APP" /Applications/
  open /Applications/LidCaffeinate.app
  echo "installed to /Applications and launched"
fi
