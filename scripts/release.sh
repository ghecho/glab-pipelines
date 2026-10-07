#!/bin/sh
# Builds a signed, notarized Pipelines and publishes it as a GitHub release with a Sparkle appcast.
# Run it on the Mac that holds the Developer ID certificate and the Sparkle private key.
# See docs/RELEASING.md for the one-time setup and for each variable.
set -eu
cd "$(dirname "$0")/.."

for NAME in SIGN_IDENTITY NOTARY_PROFILE SPARKLE_PUBLIC_KEY GITHUB_REPO; do
  eval "VALUE=\${$NAME:-}"
  if [ -z "$VALUE" ]; then
    echo "Set $NAME first. See docs/RELEASING.md." >&2
    exit 1
  fi
done

VERSION="$(cat VERSION)"
TAG="v$VERSION"
if gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
  echo "Release $TAG already exists in $GITHUB_REPO. Raise the number in VERSION." >&2
  exit 1
fi

# GitHub redirects this address to the appcast of the newest release, so it never changes.
export FEED_URL="https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml"
NO_INSTALL=1 scripts/bundle.sh

OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"
ZIP="$OUT/Pipelines-$VERSION.zip"

# Notarize, then staple the ticket to the app, so it opens with no warning even offline.
# The stapled app goes into a new zip, because the zip sent to Apple has no ticket.
ditto -c -k --keepParent build/Pipelines.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple build/Pipelines.app
rm "$ZIP"
ditto -c -k --keepParent build/Pipelines.app "$ZIP"

# generate_appcast ships in Sparkle's release archive, at the version Package.resolved pins.
SPARKLE_VERSION="$(grep -o '"version" : "[^"]*"' Package.resolved | head -1 | cut -d'"' -f4)"
TOOLS="build/sparkle-$SPARKLE_VERSION"
if [ ! -x "$TOOLS/bin/generate_appcast" ]; then
  mkdir -p "$TOOLS"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$TOOLS"
fi

# The appcast lists only this release. Sparkle needs only the newest version to offer an update.
# generate_appcast signs the zip with the private key that generate_keys stored in the keychain.
"$TOOLS/bin/generate_appcast" --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/$TAG/" "$OUT"

gh release create "$TAG" "$ZIP" "$OUT/appcast.xml" \
  --repo "$GITHUB_REPO" --title "Pipelines $VERSION" --notes "Pipelines $VERSION"
echo "Published $TAG to https://github.com/$GITHUB_REPO/releases/tag/$TAG"
