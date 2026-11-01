#!/usr/bin/env bash
# Downloads the sherpa-onnx macOS arm64 runtime and the multilingual Nemotron 3.5 streaming model
# into ~/.airtype-experiment (override with AIRTYPE_EXPERIMENT_DIR). Safe to re-run.
set -euo pipefail

EXP_DIR="${AIRTYPE_EXPERIMENT_DIR:-$HOME/.airtype-experiment}"
SHERPA_VERSION="v2.0.1"
RUNTIME_NAME="sherpa-onnx-${SHERPA_VERSION}-osx-arm64-shared"
MODEL_NAME="${NEMOTRON_MODEL_NAME:-sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11}"

mkdir -p "$EXP_DIR/runtime" "$EXP_DIR/models"

if [[ ! -f "$EXP_DIR/runtime/$RUNTIME_NAME/lib/libsherpa-onnx-c-api.dylib" ]]; then
  echo "Downloading sherpa-onnx runtime $SHERPA_VERSION..."
  curl -fL -o "$EXP_DIR/runtime/$RUNTIME_NAME.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_VERSION}/${RUNTIME_NAME}.tar.bz2"
  tar -xjf "$EXP_DIR/runtime/$RUNTIME_NAME.tar.bz2" -C "$EXP_DIR/runtime"
  rm "$EXP_DIR/runtime/$RUNTIME_NAME.tar.bz2"
  xattr -dr com.apple.quarantine "$EXP_DIR/runtime/$RUNTIME_NAME" 2>/dev/null || true
else
  echo "sherpa-onnx runtime already present."
fi

if [[ ! -f "$EXP_DIR/models/$MODEL_NAME/encoder.int8.onnx" ]]; then
  echo "Downloading $MODEL_NAME (~650 MB)..."
  curl -fL -o "$EXP_DIR/models/$MODEL_NAME.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${MODEL_NAME}.tar.bz2"
  tar -xjf "$EXP_DIR/models/$MODEL_NAME.tar.bz2" -C "$EXP_DIR/models"
  rm "$EXP_DIR/models/$MODEL_NAME.tar.bz2"
else
  echo "Model already present."
fi

echo
echo "Runtime: $EXP_DIR/runtime/$RUNTIME_NAME"
echo "Model:   $EXP_DIR/models/$MODEL_NAME"
