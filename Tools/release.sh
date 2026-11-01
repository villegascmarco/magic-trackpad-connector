#!/bin/bash
# Build the app, wrap it in a DMG and (optionally) upload it as a
# draft GitHub release. Nothing is public until you press Publish on GitHub.
#   Tools/release.sh                # build/release/Magic-Trackpad-Connector-<version>.dmg
#   Tools/release.sh --publish      # same, then draft release v<version> on GitHub
# Version = MARKETING_VERSION in the Xcode project; bump it before each release.
#
# Developer ID (optional, removes the Gatekeeper warning): set
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE=<name>   # once: xcrun notarytool store-credentials <name>
# Without them the app is ad-hoc signed and users must click "Open Anyway".
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_NAME="magic-trackpad-connector"
VOL_NAME="Magic Trackpad Connector"
VERSION=$(grep -m1 'MARKETING_VERSION' "$APP_NAME.xcodeproj/project.pbxproj" | sed 's/.*= *\(.*\);/\1/')
OUT="build/release"
DMG="$OUT/Magic-Trackpad-Connector-$VERSION.dmg"
PUBLISH=0
[[ "${1:-}" == "--publish" ]] && PUBLISH=1

if [[ $PUBLISH == 1 ]] && gh release view "v$VERSION" >/dev/null 2>&1; then
  echo "Release v$VERSION already exists — bump MARKETING_VERSION first." >&2
  exit 1
fi

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  SIGNING=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual
           ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp)
else
  SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
fi

echo "==> Building $VERSION"
rm -rf "$OUT"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
  -configuration Release -derivedDataPath build/dd -destination "generic/platform=macOS" \
  ARCHS=arm64 "${SIGNING[@]}" \
  clean build | grep -E '^(\*\*|error:|warning: .*signing)' || true
APP="build/dd/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "Build failed (no $APP)" >&2; exit 1; }

echo "==> Making $DMG"
STAGE="$OUT/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing (a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi
shasum -a 256 "$DMG"

[[ $PUBLISH == 1 ]] || { echo "Done. Run with --publish to upload."; exit 0; }

echo "==> Draft release v$VERSION"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  OPEN_NOTE="Open the DMG and drag the app to Applications."
else
  OPEN_NOTE="Open the DMG and drag the app to Applications. The app isn't notarized, so the first launch is blocked: open **System Settings → Privacy & Security** and click **Open Anyway**. On a company-managed Mac where that only shows the warning again, run \`xattr -dr com.apple.quarantine /Applications/magic-trackpad-connector.app\` in Terminal."
fi
gh release create "v$VERSION" "$DMG" --draft --title "Magic Trackpad Connector $VERSION" \
  --notes "Install on **both** Macs (macOS 26.2 or later). $OPEN_NOTE Then follow the setup steps in the README."
echo "Draft created — review and publish it at:"
gh release view "v$VERSION" --json url -q .url
