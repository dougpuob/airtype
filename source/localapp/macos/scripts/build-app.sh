#!/usr/bin/env bash
# Builds dist/AirType.app (bundle id kept separate from any prior installs via com.airtype.nemotron-experiment).
# Bundle id kept as com.airtype.nemotron-experiment so existing settings (UserDefaults) carry over.
set -euo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../../.." && pwd)"
AIRTYPE_HOME="${AIRTYPE_HOME:-$HOME/.airtype}"
SHERPA_DIR="${SHERPA_ONNX_DIR:-$AIRTYPE_HOME/models/asr/runtime/sherpa-onnx-v2.0.1-osx-arm64-shared}"
APP_NAME="AirType"
BUNDLE_ID="com.airtype.nemotron-experiment"
DIST_DIR="$APP_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"

# Resolve signing identity BEFORE building so a missing identity fails fast
# and does not leave a half-assembled dist/AirType.app.
# Stable local development signing (explicit identity only).
# Daily builds must use ONE chosen identity. Do NOT auto-pick Apple Development
# if it appears later — that would change the designated requirement and force
# another Accessibility / Input Monitoring re-grant.
#
# Set explicitly, e.g.:
#   CODESIGN_IDENTITY="AirType Local Dev" ./scripts/build-app.sh
#   CODESIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh
# Optional default file (one line, identity name) once the parent picks daily identity:
#   echo 'AirType Local Dev' > scripts/codesign-identity
# Emergency ad-hoc only (breaks TCC on every rebuild):
#   AIRTYPE_ALLOW_ADHOC=1 ./scripts/build-app.sh
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$CODESIGN_IDENTITY" && -f "$APP_ROOT/scripts/codesign-identity" ]]; then
  CODESIGN_IDENTITY="$(head -1 "$APP_ROOT/scripts/codesign-identity" | tr -d '\r' | sed 's/[[:space:]]*$//')"
fi
if [[ -z "$CODESIGN_IDENTITY" ]]; then
  if [[ "${AIRTYPE_ALLOW_ADHOC:-}" == "1" ]]; then
    CODESIGN_IDENTITY="-"
  else
    echo "error: CODESIGN_IDENTITY is not set (and scripts/codesign-identity is missing)." >&2
    echo "Pick one stable identity and export it, or write it to scripts/codesign-identity." >&2
    echo "Available codesigning identities:" >&2
    security find-identity -p codesigning 2>/dev/null | sed -E 's/[0-9A-F]{40}/[HASH]/g' >&2 || true
    echo "Emergency ad-hoc (not for normal dig): AIRTYPE_ALLOW_ADHOC=1 $0" >&2
    exit 1
  fi
fi

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "WARNING: signing ad-hoc (-). TCC grants will NOT survive the next rebuild." >&2
else
  # Accept matching (even CSSMERR_TP_NOT_TRUSTED self-signed) — codesign uses it as a DR anchor.
  if ! security find-identity -p codesigning 2>/dev/null | grep -F "\"$CODESIGN_IDENTITY\"" >/dev/null; then
    echo "error: codesigning identity not in keychain: $CODESIGN_IDENTITY" >&2
    security find-identity -p codesigning 2>/dev/null | sed -E 's/[0-9A-F]{40}/[HASH]/g' >&2 || true
    exit 1
  fi
fi



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
  <key>CFBundleDisplayName</key><string>AirType</string>
  <key>CFBundleIconFile</key><string>AirType</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1-experiment</string>
  <key>CFBundleVersion</key><string>0.0.1</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.airtype.localapp</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>airtype</string>
      </array>
    </dict>
  </array>
  <key>NSMicrophoneUsageDescription</key><string>AirType streams microphone audio to a local speech recognizer.</string>
  <key>NSAccessibilityUsageDescription</key><string>AirType listens for the global hotkey and types recognized text into the focused app.</string>
  <key>NSInputMonitoringUsageDescription</key><string>AirType listens for Escape while recording to cancel dictation.</string>
  <key>NSAppleEventsUsageDescription</key><string>AirType activates the previous app so it can paste text.</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
    <key>NSExceptionDomains</key>
    <dict>
      <key>msm4max.tail84298.ts.net</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSIncludesSubdomains</key><true/>
      </dict>
      <key>tail84298.ts.net</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSIncludesSubdomains</key><true/>
      </dict>
    </dict>
  </dict>
</dict>
</plist>
PLIST

echo "Signing with identity: $CODESIGN_IDENTITY"
# Sign nested dylibs first, then the app.
for lib in "$CONTENTS_DIR/Frameworks/"*.dylib; do
  [[ -f "$lib" ]] || continue
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp=none "$lib"
done
codesign --force --sign "$CODESIGN_IDENTITY" --timestamp=none "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "--- designated requirement ---"
codesign -d -r- "$APP_DIR" 2>&1
echo "--- signature summary ---"
codesign -dvvv "$APP_DIR" 2>&1 | egrep 'Identifier=|Format=|Signature=|Authority=|TeamIdentifier=|CDHash=|CodeDirectory|flags='
echo
echo "Built: $APP_DIR"
echo "Run:   open \"$APP_DIR\""
