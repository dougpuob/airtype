#!/usr/bin/env bash
# Convenience: download SenseVoice (multilingual), streaming Paraformer bilingual zh-en, and
# offline Zipformer transducer zh-en, plus shared Silero VAD / OpenCC where needed.
# Requires the sherpa-onnx runtime from setup-nemotron.sh. Safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

"$ROOT/setup-sensevoice.sh"
"$ROOT/setup-paraformer.sh"
"$ROOT/setup-zipformer.sh"

echo
echo "Chinese+English models ready. Rebuild / reopen the app, then pick from"
echo "  ASR Engine ▸ Local ▸ SenseVoice Multilingual / Paraformer ZH-EN Streaming / Zipformer ZH-EN"
