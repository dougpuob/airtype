# AirType

A macOS desktop speech-to-text app. Double-press the configured hotkey to start recording — your voice is transcribed and pasted at the cursor in real time.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              LocalApp (macOS)                                │
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
│  │ ffmpeg / yt-dlp / records / ~/.airtype-config.toml coordination      │    │
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
├── config.example.toml      # Template for ~/.airtype-config.toml
├── source/
│   ├── localapp/
│   │   └── macos/               # Native SwiftUI menu bar frontend
│   └── webui/
│       ├── app/
│       │   ├── main.py          # FastAPI server, routes, job queue, LLM
│       │   ├── whisper.py       # whisper.cpp integration, ffmpeg, OpenCC
│       │   └── static/          # Web UI (index.html)
│       └── requirements.txt     # Python dependencies
├── scripts/                  # Setup, WebUI, and macOS build scripts
└── run.sh                    # Run the native macOS frontend
```

## Quick Start

### Prerequisites

- [uv](https://docs.astral.sh/uv/)
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (for local transcription)
- ffmpeg

### First-Time Setup

Install the required tools yourself before running the setup script. On macOS with Homebrew, one option is:

```bash
brew install uv whisper-cpp ffmpeg curl
```

Then run the setup script:

```bash
./scripts/setup.sh
```

The setup script creates `~/.airtype-config.toml` if it does not exist. AirType will not start without that file.

For media URLs that require logged-in browser cookies, configure yt-dlp in `~/.airtype-config.toml`:

```toml
[webui.yt-dlp]
cookies = ""
cookies_from_browser = "chrome"
```

Use `cookies` for a `cookies.txt` path, or `cookies_from_browser` for a browser name such as `chrome`, `safari`, `firefox`, or `edge`.


### Run

```bash
./run.sh
```

`run.sh` starts the native SwiftUI menu bar app. The frontend starts the local WebUI automatically when `~/.airtype-config.toml` uses `mode = "local"`.

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
./scripts/build-localapp-macos.sh
open dist/AirType.app
```

Runtime user data is stored outside the app:

- config: `~/.airtype-config.toml`
- Whisper models: `~/.airtype/models`

macOS will ask for Microphone permission when recording. If the global hotkey or paste action does not work, grant Accessibility permission to `AirType.app` in System Settings.


## WebUI API Endpoints

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

Configure it in the macOS menu under **Hotkey**, or set `[localapp.hotkey] trigger = "right_ctrl"` / `"right_option"` in `~/.airtype-config.toml`.

## License

Private project.
