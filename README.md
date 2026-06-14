# AirType

A cross-platform desktop speech-to-text app. Double-press the configured hotkey to start recording — your voice is transcribed and pasted at the cursor in real time.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                    LocalApp (macOS / Windows / Linux)                        │
│  ┌──────────────────┐  ┌───────────────────┐  ┌──────────────────────────┐   │
│  │ Tray/Menu App    │  │ Floating Panel    │  │ Hotkey Listener          │   │
│  │ config menus     │  │ timer + waveform  │  │ configurable double key  │   │
│  └──────────────────┘  └─────────┬─────────┘  └──────────────────────────┘   │
│                                  │ microphone audio                          │
│                                  ▼                                           │
│  ┌──────────────────────────────────────────────────────────────────────┐    │
│  │ Paste controller → clipboard + keyboard paste                        │    │
│  └──────────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────────┘
                                      │
                    HTTP API /api/transcribe, /api/settings
                                      │
┌──────────────────────────────────────────────────────────────────────────────┐
│                              WebUI (FastAPI)                                 │
│  ┌──────────────────┐  ┌───────────────────┐  ┌──────────────────────────┐   │
│  │ API Routes       │  │ Job Queue         │  │ Web UI                   │   │
│  │ multipart upload │  │ async jobs        │  │ settings + records       │   │
│  └──────────────────┘  └───────────────────┘  └──────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────────────────────┐    │
│  │ ffmpeg / yt-dlp / records / config.toml coordination                 │    │
│  └──────────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────────┘
                                      │
                    Server calls (local or remote endpoints)
                                      │
┌──────────────────────────────────────────────────────────────────────────────┐
│                              Server (Whisper / LLM)                          │
│  ┌──────────────────────────────────┐  ┌──────────────────────────────────┐  │
│  │ whisper-server                   │  │ LLM server                       │  │
│  │ whisper.cpp + model files        │  │ Ollama / llama.cpp               │  │
│  └──────────────────────────────────┘  └──────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Features

- **Floating dialog** — always-on-top panel with live timer and waveform visualization
- **Global hotkey** — double-press the configured Right Ctrl or Right Option key to toggle recording
- **Real-time paste** — transcription result is pasted at the cursor in the active app
- **Clipboard restore** — original clipboard content is restored after 5 seconds
- **Background ASR** — transcription runs in a background thread with detailed timing logs
- **Voice activity detection** — recordings below RMS threshold are skipped
- **URL transcription** — download and transcribe audio/video from YouTube, Bilibili, Instagram, TikTok, etc.
- **Async job queue** — long-running transcriptions run as background jobs with progress tracking
- **Local LLM chat** — query transcripts with ollama or llama.cpp models
- **Web UI** — settings management, transcription records, and configuration
- **Language conversion** — OpenCC support for Simplified ↔ Traditional Chinese

## Project Structure

```
AirType.git/
├── config.example.toml      # Example local configuration
├── source/
│   ├── localapp/
│   │   └── macos/               # Native SwiftUI menu bar frontend
│   └── webui/
│       ├── app/
│       │   ├── main.py          # FastAPI server, routes, job queue, LLM
│       │   ├── whisper.py       # whisper.cpp integration, ffmpeg, OpenCC
│       │   └── static/          # Web UI (index.html)
│       ├── requirements.txt     # Python dependencies
│       └── start.sh             # Startup script
└── reference/               # Design references
```

## Quick Start

### Prerequisites

- Python 3.11+ (the setup script uses `uv` to install/manage this if needed)
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (for local transcription)
- ffmpeg
- yt-dlp (for URL transcription)

### First-Time Setup

```bash
./scripts/setup.sh
```

The setup script prints the tools and Python packages it is about to install, asks for confirmation, installs `uv` if you approve and it is missing, creates `.venv`, installs WebUI dependencies, and creates `config.toml` from `config.example.toml` if needed.

It also offers to prepare local transcription:

- installs `whisper-cpp` with Homebrew on macOS
- downloads the default model `ggml-large-v3-turbo-q5_0.bin`
- stores the model in `~/.airtype/models`
- updates `config.toml` Web UI settings to use that model
- records local whisper.cpp paths in `config.toml` under `[webui.whisper-server]`

### Run

```bash
./run.sh
```

`run.sh` starts the native SwiftUI menu bar app. The frontend starts the local WebUI automatically when `config.toml` uses `mode = "local"`.

### Manual WebUI

```bash
./scripts/start-webui.sh
```

### SwiftUI Frontend

```bash
cd source/localapp/macos
swift build
swift run AirTypeMac
```

### Build macOS App

```bash
./scripts/build-macos-app.sh
open dist/AirType.app
```

Runtime user data is stored outside the app:

- config: local `config.toml` or `AIRTYPE_CONFIG_PATH` (many installs symlink this to `~/.airtype/config.toml`)
- Whisper models: `~/.airtype/models`

macOS will ask for Microphone permission when recording. If the global hotkey or paste action does not work, grant Accessibility permission to `AirType.app` in System Settings.

## Configuration

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `AIRTYPE_BACKEND_ENDPOINT` | `http://localhost:8003` | WebUI API URL |
| `AIRTYPE_WHISPER_LANGUAGE` | — | Whisper language code (e.g. `zh-tw`) |
| `AIRTYPE_FLOATING_WHISPER_BEAM_SIZE` | `1` | Beam size for floating dialog transcription |
| `WHISPER_CPP_ROOT` | `~/whisper.cpp/whisper.cpp.git` | whisper.cpp source directory |
| `WHISPER_CPP_MODEL` | `[webui.whisper-server] model_dir` + `model_filename` in `config.toml` | Optional override for the GGML model file |
| `WHISPER_CPP_SERVER_BIN` | `[webui.whisper-server] server_bin` in `config.toml` | Optional override for whisper-server |
| `WHISPER_CPP_SERVER_ENDPOINT` | — | Remote whisper.cpp server URL |
| `WHISPER_CPP_SERVER_HOST` | `127.0.0.1` | Local server bind host |
| `WHISPER_CPP_SERVER_PORT` | — | Local server bind port (auto if unset) |
| `WHISPER_CPP_SERVER_ARGS` | — | Extra args for whisper-server |

### Web UI Settings (`config.toml`)

```toml
[webui.storage]
# Records are stored under data_dir/records/{ime,transcript}.
data_dir = "~/.airtype/data"

[webui.whisper-server]
model_dir = "~/.airtype/models"
model_filename = "ggml-large-v3-turbo-q5_0.bin"
server_bin = "/opt/homebrew/bin/whisper-server"
endpoint = ""
language = "zh-tw"
beam = 5
temperature = 0

[[webui.llm-server]]
name = "default"
provider = "llama.cpp"
endpoint = "http://127.0.0.1:8088/"
models = ["unsloth/gemma-4-E2B-it-GGUF:Q4_K_XL"]
selected-model = "unsloth/gemma-4-E2B-it-GGUF:Q4_K_XL"
contextLength = 8192
temperature = 0.4
system = ""

[webui]
default-llm-server-name = "default"
```

## API Endpoints

| Method 	| Path                            	| Description                    	|
|--------	|---------------------------------	|--------------------------------	|
| GET    	| /                               	| Health check                   	|
| GET    	| /api/settings                   	| Get app settings               	|
| PUT    	| /api/settings                   	| Update app settings            	|
| POST   	| /api/transcribe                 	| Transcribe uploaded audio      	|
| POST   	| /api/transcribe/url             	| Transcribe from URL (sync)     	|
| POST   	| /api/transcribe/jobs            	| Create async transcription job 	|
| GET    	| /api/transcribe/jobs/:id        	| Get job status                 	|
| POST   	| /api/transcribe/jobs/:id/cancel 	| Cancel a job                   	|
| GET    	| /api/transcribe/records         	| List all records               	|
| GET    	| /api/transcribe/records/:id     	| Get a record                   	|
| PATCH  	| /api/transcribe/records/:id     	| Update record title            	|
| DELETE 	| /api/transcribe/records/:id     	| Delete a record                	|
| POST   	| /api/local-llm/models           	| List local LLM models          	|
| POST   	| /api/local-llm/chat             	| Chat with local LLM            	|

## macOS Setup

Global keyboard monitoring requires Accessibility permission:

1. **System Settings** → **Privacy & Security** → **Accessibility**
2. Add and enable `AirType.app` when using the packaged macOS app
3. Restart `AirType.app`

## Hotkey

| Action | Key |
|---|---|
| Start/Stop recording | Double-press configured **Right Ctrl** or **Right Option** |

Configure it in the macOS menu under **Hotkey**, or set `[localapp.hotkey] trigger = "right_ctrl"` / `"right_option"` in `config.toml`.

## License

Private project.
