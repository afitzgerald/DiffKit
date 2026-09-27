#!/usr/bin/env bash
# Runs the diffkit-preview harness in the iOS Simulator.
#
#   scripts/preview-ios.sh                       the booted simulator
#   DEVICE="iPhone 18 Pro" scripts/preview-ios.sh
#   SCREENSHOT=out.png scripts/preview-ios.sh    also save a screenshot once it has loaded
#
# SwiftPM cannot produce an iOS app, so this builds the executable with xcodebuild and wraps
# it in a minimal .app by hand. Needs Xcode (the iOS SDK is not in CommandLineTools).
set -euo pipefail

DEVICE="${DEVICE:-booted}"
BUNDLE_ID="dev.diffkit.preview"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/.build/ios-preview"
APP="$DERIVED/DiffKitPreview.app"

cd "$ROOT"
xcodebuild -quiet -scheme diffkit-preview -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED" build

if [[ -d "$APP" ]]; then trash "$APP"; fi
mkdir -p "$APP"
cp "$DERIVED/Build/Products/Debug-iphonesimulator/diffkit-preview" "$APP/diffkit-preview"
cat > "$APP/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>diffkit-preview</string>
  <key>CFBundleName</key><string>DiffKit</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>MinimumOSVersion</key><string>18.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UILaunchScreen</key><dict/>
</dict></plist>
EOF
codesign --force --sign - "$APP" >/dev/null

xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch --terminate-running-process "$DEVICE" "$BUNDLE_ID" >/dev/null
echo "Launched $BUNDLE_ID on $DEVICE"

if [[ -n "${SCREENSHOT:-}" ]]; then
  sleep 4
  xcrun simctl io "$DEVICE" screenshot "$SCREENSHOT" >/dev/null
  echo "Saved $SCREENSHOT"
fi
