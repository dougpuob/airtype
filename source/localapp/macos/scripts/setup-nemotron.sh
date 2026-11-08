#!/usr/bin/env bash
# Downloads the sherpa-onnx macOS arm64 runtime and the multilingual Nemotron 3.5 streaming model
# into ~/.airtype/models/asr (override with AIRTYPE_HOME). Safe to re-run.
set -euo pipefail

AIRTYPE_HOME="${AIRTYPE_HOME:-$HOME/.airtype}"
ASR_DIR="$AIRTYPE_HOME/models/asr"
RUNTIME_DIR="$ASR_DIR/runtime"
SHERPA_VERSION="v2.0.1"
RUNTIME_NAME="sherpa-onnx-${SHERPA_VERSION}-osx-arm64-shared"
MODEL_NAME="${NEMOTRON_MODEL_NAME:-sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11}"

mkdir -p "$RUNTIME_DIR" "$ASR_DIR"

if [[ ! -f "$RUNTIME_DIR/$RUNTIME_NAME/lib/libsherpa-onnx-c-api.dylib" ]]; then
  echo "Downloading sherpa-onnx runtime $SHERPA_VERSION..."
  curl -fL -o "$RUNTIME_DIR/$RUNTIME_NAME.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_VERSION}/${RUNTIME_NAME}.tar.bz2"
  tar -xjf "$RUNTIME_DIR/$RUNTIME_NAME.tar.bz2" -C "$RUNTIME_DIR"
  rm "$RUNTIME_DIR/$RUNTIME_NAME.tar.bz2"
  xattr -dr com.apple.quarantine "$RUNTIME_DIR/$RUNTIME_NAME" 2>/dev/null || true
else
  echo "sherpa-onnx runtime already present."
fi

if [[ ! -f "$ASR_DIR/$MODEL_NAME/encoder.int8.onnx" ]]; then
  echo "Downloading $MODEL_NAME (~650 MB)..."
  curl -fL -o "$ASR_DIR/$MODEL_NAME.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${MODEL_NAME}.tar.bz2"
  tar -xjf "$ASR_DIR/$MODEL_NAME.tar.bz2" -C "$ASR_DIR"
  rm "$ASR_DIR/$MODEL_NAME.tar.bz2"
else
  echo "Model already present."
fi

echo
echo "Runtime: $RUNTIME_DIR/$RUNTIME_NAME"
echo "Model:   $ASR_DIR/$MODEL_NAME"
