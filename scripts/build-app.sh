#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP_NAME=Tether
BUNDLE_ID="${BUNDLE_ID:-nl.theredhead.tether}"
VERSION="${VERSION:-1.0.0}"
PREVIOUS_BUILD=0
if [[ -f "dist/$APP_NAME.app/Contents/Info.plist" ]]; then
    PREVIOUS_BUILD=$(plutil -extract CFBundleVersion raw "dist/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || echo 0)
fi
if [[ ! "$PREVIOUS_BUILD" =~ ^[0-9]+$ ]]; then PREVIOUS_BUILD=0; fi
BUILD_NUMBER="${BUILD_NUMBER:-$((PREVIOUS_BUILD + 1))}"
ARCH="${ARCH:-$(uname -m)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SWIFT_FLAGS=(-c release --arch "$ARCH")
if [[ "${DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then SWIFT_FLAGS+=(--disable-sandbox); fi
swift build "${SWIFT_FLAGS[@]}"
BIN_DIR=$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)
APP="dist/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
./scripts/build-icon.sh
cp Assets/Tether.icns "$APP/Contents/Resources/Tether.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Tether</string>
<key>CFBundleDisplayName</key><string>Tether</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>Tether</string>
<key>CFBundleIconFile</key><string>Tether.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
# Mark rebuilt bundles as changed so Finder can refresh their cached metadata.
touch "$APP"
echo "Built $APP ($ARCH). Copy to /Applications before enabling login startup."
