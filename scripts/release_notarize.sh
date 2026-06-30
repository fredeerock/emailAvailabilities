#!/usr/bin/env zsh
set -euo pipefail

# Quick Availability: CLI build + Developer ID sign + notarize + staple
# Usage:
#   1) First run (stores notary credentials in keychain):
#      APPLE_ID="you@example.com" ./scripts/release_notarize.sh --init-credentials
#   2) Normal release run:
#      ./scripts/release_notarize.sh

APP_NAME="Quick Availability.app"
BIN_NAME="AppleAvailabilityApp"
BUNDLE_ID="com.fredeerock.quickavailability"
TEAM_ID="S6254DL92P"
DEV_ID="Developer ID Application: Frederick Ostrenko (S6254DL92P)"
PROFILE_NAME="quickavailability-notary"
ZIP_NAME="Quick Availability.zip"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAGE_DIR="$(mktemp -d /tmp/quickavailability-release.XXXXXX)"
APP_PATH="$STAGE_DIR/$APP_NAME"
ZIP_PATH="$ROOT_DIR/$ZIP_NAME"

cleanup() {
  rm -rf "$STAGE_DIR"
}

trap cleanup EXIT

cd "$ROOT_DIR"

if [[ "${1:-}" == "--init-credentials" ]]; then
  if [[ -z "${APPLE_ID:-}" ]]; then
    echo "APPLE_ID is required for --init-credentials"
    echo "Example: APPLE_ID=\"you@example.com\" ./scripts/release_notarize.sh --init-credentials"
    exit 1
  fi

  echo "Enter your Apple app-specific password when prompted."
  read -r -s "NOTARY_PASS?App-specific password: "
  echo

  xcrun notarytool store-credentials "$PROFILE_NAME" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$NOTARY_PASS"

  echo "Credentials saved to keychain profile: $PROFILE_NAME"
  exit 0
fi

echo "Building release binary..."
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP_PATH" "$ZIP_PATH" "$ROOT_DIR/$APP_NAME"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp ".build/release/$BIN_NAME" "$APP_PATH/Contents/MacOS/$BIN_NAME"
cp "assets/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$BIN_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Quick Availability</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSCalendarsUsageDescription</key>
  <string>This app reads your calendar events to generate meeting availability options.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

chmod +x "$APP_PATH/Contents/MacOS/$BIN_NAME"

# Remove extended attributes that can break codesign sealing.
xattr -cr "$APP_PATH" || true
for attr in com.apple.FinderInfo com.apple.fileprovider.fpfs#P com.apple.ResourceFork com.apple.macl com.apple.provenance; do
  xattr -dr "$attr" "$APP_PATH" 2>/dev/null || true
done

echo "Signing with Developer ID..."
codesign --force --deep --options runtime --timestamp \
  --sign "$DEV_ID" \
  "$APP_PATH"

echo "Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Creating notarization zip..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Submitting for notarization and waiting for result..."
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$PROFILE_NAME" \
  --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

echo "Validating stapled ticket and Gatekeeper assessment..."
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

ditto "$APP_PATH" "$ROOT_DIR/$APP_NAME"

echo "Done: $APP_NAME is signed, notarized, and stapled."
