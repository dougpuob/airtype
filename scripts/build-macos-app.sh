#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRONTEND_DIR="$ROOT_DIR/frontend/macos"
APP_NAME="AirType"
BUNDLE_ID="com.airtype.app"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
BINARY_NAME="AirTypeMac"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This build script is intended for macOS."
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is not available."
  echo
  echo "Install Xcode or Xcode Command Line Tools first:"
  echo "  xcode-select --install"
  exit 1
fi

echo "Building SwiftUI frontend..."
swift build --package-path "$FRONTEND_DIR" -c release

echo
echo "Creating $APP_NAME.app..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"

cp "$FRONTEND_DIR/.build/release/$BINARY_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>0.1.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>AirType records microphone audio for speech-to-text transcription.</string>
  <key>NSAccessibilityUsageDescription</key>
  <string>AirType listens for the global hotkey and sends the paste shortcut to insert transcribed text.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>AirType activates the previous app so it can paste transcribed text.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  echo "Ad-hoc signing $APP_NAME.app..."
  codesign --force --deep --sign - "$APP_DIR"
fi

echo
echo "Build complete:"
echo "  dist/$APP_NAME.app"
echo
echo "Run it with:"
echo "  open dist/$APP_NAME.app"
