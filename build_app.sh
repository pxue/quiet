#!/bin/bash
# Builds Quiet.app (menu-bar noise reduction + voice isolation) into ./dist.
set -euo pipefail
cd "$(dirname "$0")"

export MACOSX_DEPLOYMENT_TARGET=14.0
(cd dfcore && CARGO_NET_GIT_FETCH_WITH_CLI=true cargo build --release)
swift build -c release

APP=dist/Quiet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Quiet "$APP/Contents/MacOS/Quiet"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Quiet</string>
    <key>CFBundleIdentifier</key><string>ltd.spacestationlabs.quiet</string>
    <key>CFBundleName</key><string>Quiet</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Quiet cleans up your microphone audio on this Mac before sending it to your call apps.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
