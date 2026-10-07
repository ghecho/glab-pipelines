#!/bin/sh
# Builds build/Pipelines.app and installs it to /Applications.
# macOS sends notifications only for a bundled, signed app.
#
# Optional environment, used by scripts/release.sh (see docs/RELEASING.md):
#   SIGN_IDENTITY       a Developer ID identity. Without it, the app is signed ad hoc.
#   FEED_URL            the Sparkle appcast URL. Without it, the app never looks for updates.
#   SPARKLE_PUBLIC_KEY  the public EdDSA key that matches the key that signs the updates.
#   NO_INSTALL=1        build only, do not replace the copy in /Applications.
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product Pipelines
BIN="$(swift build -c release --show-bin-path)"
APP=build/Pipelines.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Pipelines" "$APP/Contents/MacOS/Pipelines"

# Sparkle. ditto keeps the framework's symlinks, which its signature depends on. Pipelines is not
# sandboxed, so Sparkle's XPC services are not needed, and Sparkle's docs allow removing them.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$BIN/Sparkle.framework" "$SPARKLE"
rm -rf "$SPARKLE/XPCServices" "$SPARKLE/Versions/B/XPCServices"

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

# Sparkle compares CFBundleVersion, so it must grow with every release. The commit count does.
VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
UPDATES=""
if [ -n "${FEED_URL:-}" ]; then
  UPDATES="  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY:?Set SPARKLE_PUBLIC_KEY together with FEED_URL}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>tech.vitenskap.glab.pipelines</string>
  <key>CFBundleName</key><string>Pipelines</string>
  <key>CFBundleExecutable</key><string>Pipelines</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
$UPDATES
</dict>
</plist>
PLIST

# Sign from the inside out: Sparkle's helpers, then the framework, then the app. A Developer ID
# signature needs the hardened runtime and a secure timestamp, which notarization requires.
IDENTITY="${SIGN_IDENTITY:--}"
FLAGS=""
if [ "$IDENTITY" != "-" ]; then FLAGS="--options runtime --timestamp"; fi
for PART in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE" "$APP"; do
  codesign --force --sign "$IDENTITY" $FLAGS "$PART"
done

if [ "${NO_INSTALL:-}" = "1" ]; then
  echo "$APP"
  exit 0
fi

# Replace the installed copy and start it again. The login item points at this path.
pkill -x Pipelines || true
rm -rf /Applications/Pipelines.app
cp -R "$APP" /Applications/
open /Applications/Pipelines.app
echo /Applications/Pipelines.app
