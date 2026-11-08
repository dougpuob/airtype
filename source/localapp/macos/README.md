# AirType localapp (macOS) — Local ONNX + Remote ASR dictation

Fork of `source/localapp/macos` (the original AirType Swift menu bar app is untouched).
Same shell — menu bar item, double Right Ctrl / Right Option hotkey, Escape to cancel,
floating panel, microphone menus — but speech recognition runs **locally and streams**:

```
mic (AVAudioEngine, 16 kHz Int16) ──► sherpa-onnx C API (in-process)
                                     └► NVIDIA Nemotron 3.5 ASR Streaming 0.6B, int8, 560 ms chunks
partial text ──► floating panel + typed live into the focused app
```

No whisper-server, no WebUI backend, no network.

## Setup (once)

```bash
cd source/localapp/macos
./scripts/setup-nemotron.sh     # sherpa-onnx v2.0.1 osx-arm64 runtime + model (~650 MB)
./scripts/build-app.sh          # -> dist/AirType.app
```

Quit the original **AirType.app** first (both use the same hotkey), then:

```bash
open dist/AirType.app
```

New bundle id (`com.airtype.nemotron-experiment`), so macOS asks again for
Microphone and Accessibility (System Settings ▸ Privacy & Security). Input Monitoring may be
needed for the hotkey, the same as the original app.

## Qwen3-ASR engine (default since 2026-10-31)

Menu bar ▸ **ASR Engine** switches between:

- **Qwen3-ASR 0.6B int8** (default) — much better at 中英夾雜 (review / deploy / pull request /
  Kubernetes stay English), punctuation included. Not truly streaming: Silero VAD cuts at pauses
  (≥0.5 s); each finished phrase is decoded once and fixed, the phrase you are still saying is
  re-decoded about every 1 s as a draft (may still change). Text arrives in bursts, not per word.
  Stop → final in ~0.4–0.5 s. Each re-decode costs ~0.3 s CPU on M4 Max.
- **Nemotron 3.5 streaming** — word-by-word, weaker on mixed zh/en.

Setup (once, after `setup-nemotron.sh` which provides the sherpa-onnx runtime):

```bash
./scripts/setup-qwen3.sh   # model (~970 MB) + silero_vad.onnx + brew install opencc
./scripts/build-app.sh
```

zh-tw output: menu ▸ **zh-tw: OpenCC s2twp** (on by default when `opencc` is installed) converts
Simplified → Traditional with Taiwan phrasing (软件→軟體, 信息→資訊); off = macOS Hans-Hant.

Tuning (environment variables; `open` does not pass env, so
run `dist/AirType.app/Contents/MacOS/AirType &` from a shell):

| Variable | Default | Meaning |
|---|---|---|
| `AIRTYPE_ASR_ENGINE` | menu choice, else `qwen3` | `qwen3`, `qwen3-1.7b`, `funasr-nano`, `sensevoice`, `paraformer`, `zipformer`, or `nemotron` |
| `AIRTYPE_QWEN3_MODEL_DIR` | `~/.airtype/models/asr/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25` | e.g. a 1.7B export |
| `AIRTYPE_QWEN3_PARTIAL_SECONDS` | `1.0` | draft re-decode interval |
| `AIRTYPE_QWEN3_MIN_SILENCE` | `0.5` | pause (s) that closes a phrase |
| `AIRTYPE_QWEN3_MAX_SEGMENT` | `15` | force-split long phrases (s) |
| `AIRTYPE_QWEN3_THREADS` | `4` | ONNX threads |
| `AIRTYPE_OPENCC` | (on) | `0` disables OpenCC |

Hotwords (bias toward your terms): put one per line in `~/.airtype/qwen3-hotwords.txt`
(or `AIRTYPE_QWEN3_HOTWORDS="foo,bar"`), then restart the app.

**Qwen3-ASR 1.7B int8** (added 2026-10-31): menu ▸ ASR Engine ▸ **Qwen3-ASR 1.7B** (or
`AIRTYPE_ASR_ENGINE=qwen3-1.7b`). Same loop, sherpa config, `AIRTYPE_QWEN3_*` knobs and hotwords file as
0.6B; more accurate but ~2x slower per decode, ~2.4 GB on disk, ~2.5–3 GB RAM. Install with
`./scripts/setup-qwen3-1.7b.sh` (ModelScope `zengshuishui/Qwen3-ASR-onnx` `model_1.7B`, SHA-256 verified)
into `~/.airtype/models/asr/qwen3-asr-1.7B-int8` (override: `AIRTYPE_QWEN3_1_7B_MODEL_DIR`).
If drafts lag, raise `AIRTYPE_QWEN3_PARTIAL_SECONDS` (e.g. 2.0).

Self-test: `AIRTYPE_ASR_ENGINE=qwen3 dist/AirType.app/Contents/MacOS/AirType --selftest-wav x.wav zh-tw`

## Fun-ASR-Nano engine (added 2026-10-31)

Menu bar ▸ **ASR Engine** ▸ **Fun-ASR-Nano 2512** (or `AIRTYPE_ASR_ENGINE=funasr-nano`).
Fun-ASR-Nano-2512 (Alibaba FunAudioLLM; audio encoder + Qwen3-0.6B LLM, zh / en / ja, 7 Chinese
dialects + many accents) via sherpa-onnx `funasr_nano`, int8. Offline-only model, so it uses the
same Silero VAD + ~1 s draft re-decode loop as Qwen3-ASR (bursty, not word-by-word). ITN is on
(punctuation, digits). Output is Simplified; the zh-tw OpenCC s2twp toggle applies the same way.

```bash
./scripts/setup-funasr-nano.sh   # model (~840 MB download, ~1 GB unpacked) + silero_vad + opencc
./scripts/build-app.sh
```

| Variable | Default | Meaning |
|---|---|---|
| `AIRTYPE_FUNASR_MODEL_DIR` | `~/.airtype/models/asr/sherpa-onnx-funasr-nano-int8-2025-12-30` | e.g. the fp16 / fp32 sherpa tarballs |
| `AIRTYPE_FUNASR_LANGUAGE` | `` (auto) | e.g. `中文` / `英文` to force |
| `AIRTYPE_FUNASR_ITN` | `1` | `0` = raw text |
| `AIRTYPE_FUNASR_PARTIAL_SECONDS` / `_MIN_SILENCE` / `_MAX_SEGMENT` / `_THREADS` | 1.0 / 0.5 / 15 / 4 | same as the Qwen3 knobs |
| `AIRTYPE_FUNASR_HOTWORDS` | — | comma list; else `~/.airtype/funasr-hotwords.txt`, else `qwen3-hotwords.txt` |

Both pause-chunked engines share `Qwen3ASREngine.swift` (`Qwen3ASREngine(model: .funasrNano)`).

## SenseVoice / Paraformer / Zipformer (zh+en capable)

| Menu | Engine id | Mode | Default model | Languages |
|---|---|---|---|---|
| **SenseVoice Multilingual** | `sensevoice` | offline VAD | `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17` (~155 MB) | zh / en / ja / ko / yue |
| **Paraformer ZH-EN Streaming** | `paraformer` | true streaming | `sherpa-onnx-streaming-paraformer-bilingual-zh-en` (~1 GB) | zh + en (+ dialects) |
| **Zipformer ZH-EN** | `zipformer` | offline VAD transducer | `sherpa-onnx-zipformer-zh-en-2023-11-22` (~298 MB) | zh + en |

SenseVoice / Zipformer share the Silero VAD + ~1 s draft re-decode loop with Qwen3.
Paraformer uses the same online feed/decode path as Nemotron (`ParaformerStreamingEngine`).
Output is Simplified; zh-tw OpenCC s2twp still applies.

```bash
./scripts/setup-chinese-models.sh   # all three + silero_vad + opencc
# or individually:
./scripts/setup-sensevoice.sh
./scripts/setup-paraformer.sh
./scripts/setup-zipformer.sh
./scripts/build-app.sh
```

| Variable | Default | Meaning |
|---|---|---|
| `AIRTYPE_SENSEVOICE_MODEL_DIR` / `_LANGUAGE` / `_ITN` | …/sense-voice-…-int8-2024-07-17 / `auto` / `1` | force e.g. `zh`; ITN off with `0` |
| `AIRTYPE_PARAFORMER_MODEL_DIR` | …/streaming-paraformer-bilingual-zh-en | e.g. trilingual `…-zh-cantonese-en` |
| `AIRTYPE_ZIPFORMER_MODEL_DIR` | …/zipformer-zh-en-2023-11-22 | alternate Zipformer transducer tarball |
| `AIRTYPE_SENSEVOICE_*` / `AIRTYPE_ZIPFORMER_*` VAD knobs | 1.0 / 0.5 / 15 / 4 | `PARTIAL_SECONDS` / `MIN_SILENCE` / `MAX_SEGMENT` / `THREADS` |

Self-test: `AIRTYPE_ASR_ENGINE=sensevoice dist/AirType.app/Contents/MacOS/AirType --selftest-wav x.wav zh-tw`

## Use

- Double-press Right Ctrl (or Right Option): start; text appears while you speak.
- Double-press again: stop; the last chunk is flushed (~50–100 ms) and the final text is fixed.
- Escape: cancel and delete what was typed live in this session.

Menu bar:

- **Nemotron …**: model status (loads in ~0.5 s at launch).
- **Live Typing**: on = types into the focused app while you speak (synthesized Unicode
  key events, no clipboard; tail is corrected with Backspace if the text changes).
  Off = partial text only in the floating panel, pasted once on stop (original paste path).
  If you switch apps mid-dictation, typing pauses and the rest is pasted into the original app on stop.
- **Language**: Traditional Chinese (`zh` + Simplified→Traditional conversion),
  Simplified Chinese (`zh`), English (`en`), Auto Detect (`auto`).

## Files and paths

| What | Where |
|---|---|
| sherpa-onnx runtime (dylibs + header) | `~/.airtype/models/asr/runtime/sherpa-onnx-v2.0.1-osx-arm64-shared` (`SHERPA_ONNX_DIR` / `AIRTYPE_HOME` to override) |
| ASR models | `~/.airtype/models/asr/…` (`AIRTYPE_NEMOTRON_MODEL_DIR` etc. to override a model dir) |
| Whisper models | `~/.airtype/models/whisper/` |
| Config | `~/.airtype/config.json` (shared with WebUI) |
| History DB | `~/.airtype/history.sqlite` |
| Log | `~/.airtype/airtype-localapp.log` |
| App bundle | `source/localapp/macos/dist/AirType.app` (dylibs copied into `Contents/Frameworks`) |

Other chunk sizes (80/160/1120 ms) exist: lower = snappier, higher = more accurate, e.g.
`NEMOTRON_MODEL_NAME=sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-160ms-int8-2026-06-11 ./scripts/setup-nemotron.sh`
then launch with `AIRTYPE_NEMOTRON_MODEL_DIR` pointing at it.

## Self-test without a microphone

```bash
dist/AirType.app/Contents/MacOS/AirType --selftest-wav some-16k-mono.wav zh-tw
```

Streams the WAV in real time (100 ms chunks) and prints each partial and the final text.

## Notes / limits

- Mandarin (`zh-CN`) is a "broad-coverage" locale in Nemotron 3.5 (usable, higher error rate
  than its top-tier languages). Output is Simplified; zh-tw mode converts with the macOS
  `Hans-Hant` transform (character-level, not Taiwan phrase conversion).
- The English-only `nemotron-speech-streaming-en-0.6b` is not used.
- Live typing uses Unicode key events; if a Chinese input method is active in the target app and
  intercepts them, turn Live Typing off (paste on stop).
- Experiment code paths changed vs. localapp: `NemotronStreamingEngine.swift`, `LiveTyper.swift`,
  `TranscriptFormatter.swift`, `SelfTest.swift` (new); `AirTypeCoordinator.swift`,
  `AudioRecorder.swift` (PCM callback), `FloatingPanelController.swift` (live text),
  `ConfigStore.swift` (own config path, en/auto), `Logger.swift` (own log) changed;
  `BackendClient.swift` / `BackendProcessManager.swift` removed.

## ASR Engine: Local vs Remote (merged from localapp)

Menu `ASR Engine ▸`
- `Local (ONNX, on-device) ▸` Qwen3-ASR 0.6B / 1.7B / Fun-ASR-Nano / SenseVoice / Paraformer ZH-EN / Zipformer ZH-EN / Nemotron (sherpa-onnx, in-process; live text + Live Typing).
- `Remote (Whisper via WebUI) ▸` `Whisper server: <url>` entries from `[localapp.backend-endpoint]` `remote_endpoint` / `local_endpoint`,
  plus `Test connection`. Uploads one WAV on stop to `POST <url>/api/transcribe/ime` (HTTP Basic from `[webui.auth]`); no partials,
  so Live Typing is greyed out and the result is pasted. The WebUI is **not** auto-started; it must already be running.

Shared post-processing for both: OpenCC s2twp, Arabic numerals, LLM 整理 (polish).
Language sent to the WebUI: zh-tw/auto-tw → `zh-tw`, zh-cn/auto-cn → `zh-cn`, en → `en` (best effort).

UserDefaults (`com.airtype.nemotron-experiment`): `asrBackend` (local|remote), `asrLocalModel` (legacy `asrEngine` still read),
`asrRemoteEndpoint`. Env overrides: `AIRTYPE_ASR_ENGINE=remote|qwen3|...`, `AIRTYPE_REMOTE_ENDPOINT=https://host`.
Self-test: `AIRTYPE_ASR_ENGINE=remote dist/AirType.app/Contents/MacOS/AirType --selftest-wav file.wav zh-tw`.
Future: `RemoteASRProtocol.openAITranscriptions` (`/v1/audio/transcriptions`, e.g. oMLX STT) is declared but not implemented.

## Settings window

Menu ▸ **Settings…** (⌘,) opens a sidebar editor for `~/.airtype/config.json`
(Service Providers / Endpoint Profiles / Voice Input / Others / Obsidian, including searchable History panes).
Apply/Save writes the JSON file and reloads it in-app. **ASR Engine ▸ Remote ▸ Configure…** opens the ASR Endpoints tab:

```json
{
  "localapp": {
    "remote-asr": [{
      "endpoint": "https://omlx.dougpuob.uk",
      "protocol": "openai",
      "model": "Qwen3-ASR-1.7B-8bit",
      "api_key": "..."
    }]
  }
}
```

Fetch Models tries `GET /v1/models`, then the WebUI `/api/health` + `/api/whisper-server/status`.
Test checks the server and transcribes a short `say -v Meijia` sample.
CLI check: `AirType --selftest-config` (lists models, rewrites config).
