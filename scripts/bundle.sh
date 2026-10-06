#!/bin/sh
# Builds build/Pipelines.app and installs it to /Applications.
# macOS sends notifications only for a bundled, signed app.
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product Pipelines
APP=build/Pipelines.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Pipelines" "$APP/Contents/MacOS/Pipelines"

# The icon: Resources/AppIcon.svg rendered at every size an .icns holds.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -s format png -z $SIZE $SIZE Resources/AppIcon.svg --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -s format png -z $DOUBLE $DOUBLE Resources/AppIcon.svg --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>tech.vitenskap.glab.pipelines</string>
  <key>CFBundleName</key><string>Pipelines</string>
  <key>CFBundleExecutable</key><string>Pipelines</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"

# Replace the installed copy and start it again. The login item points at this path.
pkill -x Pipelines || true
rm -rf /Applications/Pipelines.app
cp -R "$APP" /Applications/
open /Applications/Pipelines.app
echo /Applications/Pipelines.app
