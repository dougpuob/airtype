#!/usr/bin/env bash
# Downloads Fun-ASR-Nano-2512 int8 (sherpa-onnx export, ~840 MB tarball) + Silero VAD into
# ~/.airtype-experiment/models (override with AIRTYPE_EXPERIMENT_DIR), and installs OpenCC for
# zh-tw s2twp conversion if Homebrew is available. Safe to re-run.
# The sherpa-onnx runtime itself comes from setup-nemotron.sh (same v2.0.1 runtime).
set -euo pipefail

EXP_DIR="${AIRTYPE_EXPERIMENT_DIR:-$HOME/.airtype-experiment}"
MODEL_NAME="${FUNASR_MODEL_NAME:-sherpa-onnx-funasr-nano-int8-2025-12-30}"
BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"

mkdir -p "$EXP_DIR/models"

if [[ ! -f "$EXP_DIR/models/$MODEL_NAME/llm.int8.onnx" ]]; then
  echo "Downloading $MODEL_NAME (~840 MB)..."
  curl -fL -o "$EXP_DIR/models/$MODEL_NAME.tar.bz2" "$BASE/${MODEL_NAME}.tar.bz2"
  tar -xjf "$EXP_DIR/models/$MODEL_NAME.tar.bz2" -C "$EXP_DIR/models"
  rm "$EXP_DIR/models/$MODEL_NAME.tar.bz2"
else
  echo "Fun-ASR-Nano model already present."
fi

if [[ ! -f "$EXP_DIR/models/silero_vad.onnx" ]]; then
  echo "Downloading silero_vad.onnx..."
  curl -fL -o "$EXP_DIR/models/silero_vad.onnx" "$BASE/silero_vad.onnx"
else
  echo "Silero VAD already present."
fi

if ! command -v opencc >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
  echo "Installing OpenCC (s2twp for zh-tw)..."
  HOMEBREW_NO_AUTO_UPDATE=1 brew install opencc || echo "OpenCC install failed; zh-tw falls back to macOS Hans-Hant."
fi

echo
echo "Model: $EXP_DIR/models/$MODEL_NAME"
echo "VAD:   $EXP_DIR/models/silero_vad.onnx"
