#!/usr/bin/env bash
# Builds dist/AirTypeNemotron.app (experiment; separate bundle id from the original AirType.app).
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../../.." && pwd)"
SHERPA_DIR="${SHERPA_ONNX_DIR:-$HOME/.airtype-experiment/runtime/sherpa-onnx-v2.0.1-osx-arm64-shared}"
APP_NAME="AirTypeNemotron"
BUNDLE_ID="com.airtype.nemotron-experiment"
DIST_DIR="$APP_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"

if [[ ! -f "$SHERPA_DIR/lib/libsherpa-onnx-c-api.dylib" ]]; then
  echo "sherpa-onnx runtime not found at $SHERPA_DIR"
  echo "Run: $APP_ROOT/scripts/setup-nemotron.sh"
  exit 1
fi

echo "Building $APP_NAME..."
SHERPA_ONNX_DIR="$SHERPA_DIR" swift build --package-path "$APP_ROOT" -c release

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$CONTENTS_DIR/Frameworks"
cp "$APP_ROOT/.build/release/$APP_NAME" "$CONTENTS_DIR/MacOS/$APP_NAME"
cp "$SHERPA_DIR/lib/libsherpa-onnx-c-api.dylib" "$SHERPA_DIR/lib/libonnxruntime.dylib" "$CONTENTS_DIR/Frameworks/"

if [[ -f "$REPO_ROOT/scripts/generate-airtype-icon.swift" ]]; then
  swift "$REPO_ROOT/scripts/generate-airtype-icon.swift" "$CONTENTS_DIR/Resources/AirType.icns" || true
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>AirType Nemotron</string>
  <key>CFBundleIconFile</key><string>AirType</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1-experiment</string>
  <key>CFBundleVersion</key><string>0.0.1</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>AirType Nemotron streams microphone audio to a local speech recognizer.</string>
  <key>NSAccessibilityUsageDescription</key><string>AirType Nemotron listens for the global hotkey and types recognized text into the focused app.</string>
  <key>NSInputMonitoringUsageDescription</key><string>AirType Nemotron listens for Escape while recording to cancel dictation.</string>
  <key>NSAppleEventsUsageDescription</key><string>AirType Nemotron activates the previous app so it can paste text.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR"
echo
echo "Built: $APP_DIR"
echo "Run:   open \"$APP_DIR\""
