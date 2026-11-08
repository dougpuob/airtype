#!/usr/bin/env bash
# Downloads Qwen3-ASR 1.7B int8 (sherpa-onnx qwen3_asr layout, ~2.4 GB) from ModelScope
# zengshuishui/Qwen3-ASR-onnx (the export used by the sherpa-onnx Qwen3-ASR PR) into
# ~/.airtype/models/asr/qwen3-asr-1.7B-int8 (override with AIRTYPE_HOME).
# Verifies SHA-256. Safe to re-run (skips files already verified). VAD/OpenCC come from setup-qwen3.sh.
set -euo pipefail

AIRTYPE_HOME="${AIRTYPE_HOME:-$HOME/.airtype}"
ASR_DIR="$AIRTYPE_HOME/models/asr"
EXP_DIR="$ASR_DIR"
DEST="$EXP_DIR/qwen3-asr-1.7B-int8"
BASE="https://modelscope.cn/models/zengshuishui/Qwen3-ASR-onnx/resolve/master"

FILES=(
  "model_1.7B/conv_frontend.onnx conv_frontend.onnx fa894a4ba53da6a4238f2a6ca0b09362e505d39cecbd646051b033e2e8d7e2fb"
  "model_1.7B/encoder.int8.onnx encoder.int8.onnx 436fbd910a0c8914851e5ac1354e807be9f283d08a5da728adaa609731c41469"
  "model_1.7B/decoder.int8.onnx decoder.int8.onnx c43c853fa6e97d08365cb8a5502b360b595cd43c00dc60e4d8ca7cc18cad460b"
  "tokenizer/vocab.json tokenizer/vocab.json ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
  "tokenizer/merges.txt tokenizer/merges.txt 8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"
  "tokenizer/tokenizer_config.json tokenizer/tokenizer_config.json 4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"
)

mkdir -p "$DEST/tokenizer"
for entry in "${FILES[@]}"; do
  read -r src dst sha <<<"$entry"
  out="$DEST/$dst"
  if [[ -f "$out" ]] && [[ "$(shasum -a 256 "$out" | cut -d' ' -f1)" == "$sha" ]]; then
    echo "ok   $dst"
    continue
  fi
  echo "get  $dst"
  curl -fL --retry 3 -C - -o "$out.part" "$BASE/$src"
  got="$(shasum -a 256 "$out.part" | cut -d' ' -f1)"
  if [[ "$got" != "$sha" ]]; then
    echo "SHA-256 mismatch for $dst ($got)"; rm -f "$out.part"; exit 1
  fi
  mv "$out.part" "$out"
done

if [[ ! -f "$EXP_DIR/silero_vad.onnx" ]]; then
  echo "Silero VAD missing: run scripts/setup-qwen3.sh too."
fi
echo
echo "Model: $DEST ($(du -sh "$DEST" | cut -f1))"
