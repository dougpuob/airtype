#!/usr/bin/env bash
# Downloads streaming Paraformer bilingual zh+en int8 (~999 MB tarball) into
# ~/.airtype/models/asr (override with AIRTYPE_HOME), and installs OpenCC for
# zh-tw s2twp conversion if Homebrew is available. Safe to re-run.
# The sherpa-onnx runtime itself comes from setup-nemotron.sh (same v2.0.1 runtime).
#
# Alternate (zh + 粤语 + en, also streaming):
#   PARAFORMER_MODEL_NAME=sherpa-onnx-streaming-paraformer-trilingual-zh-cantonese-en
set -euo pipefail

AIRTYPE_HOME="${AIRTYPE_HOME:-$HOME/.airtype}"
ASR_DIR="$AIRTYPE_HOME/models/asr"
EXP_DIR="$ASR_DIR"
MODEL_NAME="${PARAFORMER_MODEL_NAME:-sherpa-onnx-streaming-paraformer-bilingual-zh-en}"
BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"

mkdir -p "$EXP_DIR"

if [[ ! -f "$EXP_DIR/$MODEL_NAME/encoder.int8.onnx" ]]; then
  echo "Downloading $MODEL_NAME (~1 GB)..."
  curl -fL -o "$EXP_DIR/$MODEL_NAME.tar.bz2" "$BASE/${MODEL_NAME}.tar.bz2"
  tar -xjf "$EXP_DIR/$MODEL_NAME.tar.bz2" -C "$EXP_DIR"
  rm "$EXP_DIR/$MODEL_NAME.tar.bz2"
else
  echo "Streaming Paraformer model already present."
fi

if ! command -v opencc >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
  echo "Installing OpenCC (s2twp for zh-tw)..."
  HOMEBREW_NO_AUTO_UPDATE=1 brew install opencc || echo "OpenCC install failed; zh-tw falls back to macOS Hans-Hant."
fi

echo
echo "Model: $EXP_DIR/models/$MODEL_NAME"
echo "Files: encoder.int8.onnx + decoder.int8.onnx + tokens.txt"
