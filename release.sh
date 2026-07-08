#!/bin/zsh
# Full release pipeline: build+sign app → DMG → notarize → staple → GitHub release.
# Usage: ./release.sh v1.0.0
# Reads signing config from .env-sign (gitignored). Requires the Apple Developer
# Program License Agreement to be current, or notarytool returns HTTP 403.
set -euo pipefail
cd "$(dirname "$0")"

TAG="${1:?usage: ./release.sh vX.Y.Z}"
source .env-sign   # SIGN_ID, NOTARY_PROFILE, GITHUB_REPO

APP="build/Sendling.app"
DMG="build/Sendling-${TAG}.dmg"

# 1. Build + sign the .app (build.sh signs with hardened runtime + timestamp)
./build.sh "$SIGN_ID"

# 2. Stage a DMG with a drag-to-Applications affordance
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Sendling" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

# 3. Notarize + staple
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# 4. GitHub release
git tag -f "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$DMG" --repo "$GITHUB_REPO" \
    --title "Sendling $TAG" --notes-file RELEASE_NOTES.md

echo "Released $TAG → https://github.com/$GITHUB_REPO/releases/tag/$TAG"
