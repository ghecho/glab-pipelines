#!/bin/sh
# Builds build/Pipelines.app. macOS sends notifications only for a bundled, signed app.
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product Pipelines
APP=build/Pipelines.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Pipelines" "$APP/Contents/MacOS/Pipelines"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>tech.vitenskap.glab.pipelines</string>
  <key>CFBundleName</key><string>Pipelines</string>
  <key>CFBundleExecutable</key><string>Pipelines</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
