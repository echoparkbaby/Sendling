#!/bin/zsh
# Builds, bundles, and signs Sendling.app into build/.
# Usage: ./build.sh [signing-identity]
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${1:-Developer ID Application: Brandon Walter (AQ5XNNSVN7)}"

swift build -c release --arch arm64 --arch x86_64

APP="build/Sendling.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/Sendling "$APP/Contents/MacOS/Sendling"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built and signed: $APP"
