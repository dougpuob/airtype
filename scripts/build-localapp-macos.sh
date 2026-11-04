#!/usr/bin/env bash
# Builds the macOS menu bar app from source/localapp/macos
# (Local sherpa-onnx ASR + Remote Whisper/OpenAI-compatible ASR).
# Output: source/localapp/macos/dist/AirTypeLocalInput.app
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT_DIR/source/localapp/macos/scripts/build-app.sh" "$@"
