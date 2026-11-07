#!/bin/zsh
# Builds "Drive in Finder.app" into ./build. Usage: ./build.sh [--install]
set -euo pipefail
cd "${0:A:h}"

APP="build/Drive in Finder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework SwiftUI -framework Carbon -lsqlite3 \
  Sources/*.swift -o "$APP/Contents/MacOS/Drive in Finder"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Drive in Finder</string>
  <key>CFBundleDisplayName</key><string>Drive in Finder</string>
  <key>CFBundleIdentifier</key><string>studio.upcoming.drive-in-finder</string>
  <key>CFBundleExecutable</key><string>Drive in Finder</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x "Drive in Finder" 2>/dev/null || true
  rm -rf "/Applications/Drive in Finder.app"
  cp -R "$APP" /Applications/
  open "/Applications/Drive in Finder.app"
  echo "Installed to /Applications and launched"
fi
