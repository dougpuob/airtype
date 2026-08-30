# AirType

A macOS desktop speech-to-text app. Double-press Right Ctrl or Right Option to start recording — your voice is transcribed and pasted at the cursor in real time.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              LocalApp (macOS)                                │
│  ┌──────────────────┐  ┌───────────────────┐  ┌──────────────────────────┐   │
│  │ Tray/Menu App    │  │ Floating Panel    │  │ Hotkey Listener          │   │
│  │ config menus     │  │ timer + waveform  │  │ double-key listener      │   │
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
│  │ ffmpeg / yt-dlp / records / ~/.airtype/config.toml coordination      │    │
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
- **Global hotkey** — double-press Right Ctrl or Right Option to toggle recording
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
├── config.example.toml      # Template for ~/.airtype/config.toml
├── source/
│   ├── localapp/
│   │   └── macos/               # Native SwiftUI menu bar frontend
│   └── webui/
│       ├── app/
│       │   ├── main.py          # FastAPI server, routes, job queue, LLM
│       │   ├── whisper.py       # whisper.cpp integration, ffmpeg, OpenCC
│       │   └── static/          # Web UI (index.html)
│       └── requirements.txt     # Python dependencies
└── scripts/                  # Setup, WebUI, and macOS build scripts
```

## Quick Start

### Prerequisites

- [uv](https://docs.astral.sh/uv/)
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (for local transcription)
- ffmpeg
- [Deno](https://deno.com) 2.3+ (YouTube URL transcription; yt-dlp's default JavaScript runtime)

### First-Time Setup

Install the required tools yourself before running the setup script. On macOS with Homebrew, one option is:

```bash
brew install uv whisper-cpp ffmpeg curl deno
```

Then run the setup script:

```bash
./scripts/setup.sh
```

The setup script creates `~/.airtype/config.toml` if it does not exist. AirType will not start without that file.

YouTube URL transcription needs a JavaScript runtime because yt-dlp must solve YouTube's player challenges. AirType looks for Deno first (the runtime yt-dlp enables by default), then Node.js 22+, including Homebrew paths that GUI apps often omit from `PATH`. If Deno is missing, install it and restart AirType:

```bash
brew install deno
```

Cookies are a separate setting. Use them only when a media URL requires a logged-in browser session, for example age-restricted YouTube or premium Bilibili:

```toml
[webui.yt-dlp]
cookies = ""
cookies_from_browser = "chrome"
```

Use `cookies` for a `cookies.txt` path, or `cookies_from_browser` for a browser name such as `chrome`, `safari`, `firefox`, or `edge`.

#### Keeping yt-dlp Up to Date

yt-dlp is frequently updated to support new websites and fix compatibility issues. If YouTube downloads fail with `HTTP Error 403` *after* Deno is installed, update yt-dlp:

**Using the update script:**
```bash
./scripts/update-yt-dlp.sh
```

**Manually:**
```bash
# For virtual environment
.venv/bin/python -m pip install --upgrade yt-dlp

# For system Python
python3 -m pip install --upgrade yt-dlp

# If you see "Will not install to the site-packages" error:
python3 -m pip install --upgrade yt-dlp --break-system-packages
```

**Using Homebrew (macOS):**
```bash
brew upgrade yt-dlp
```

YouTube Shorts URLs often require yt-dlp version 2026.08 or later. Regular updates ensure compatibility with YouTube's changing APIs.

For server-side Threads login, install the Playwright Chromium browser on the server, then open **Threads Login** in the Web UI:

```bash
python -m playwright install chromium
```

AirType stores the server browser profile and exported Threads cookies under the configured Web UI data directory.

Bilibili URL transcription automatically asks yt-dlp for audio first and applies browser-style headers, Chrome impersonation when available, smaller HTTP chunks, and resume-friendly retries. This avoids common `HTTP Error 412: Precondition Failed` failures from Bilibili metadata and CDN requests. Higher-quality Bilibili formats may still require a logged-in or premium account via cookies.

**YouTube downloads:** `No supported JavaScript runtime could be found` means Deno (or Node 22+) is missing, not that cookies or yt-dlp are outdated. `HTTP Error 403` after that warning is the usual follow-on failure when the player signature was not solved. Install Deno, then restart AirType. Impersonation (`--impersonate`) is used for Bilibili TLS fingerprinting and does not replace the JavaScript runtime.


### Run

```bash
./scripts/build-localapp-macos.sh
open dist/AirType.app
```

This builds and starts the native SwiftUI menu bar app. The frontend starts the local WebUI automatically when `~/.airtype/config.toml` uses `mode = "local"`.

### Manual WebUI

```bash
./scripts/start-webui.sh
```

By default, the manual WebUI listens on `0.0.0.0:8003`, which accepts
connections from the same machine and from other devices on your local network.
Open `http://<this-mac-ip>:8003`, for example `http://192.168.68.83:8003`.
Make sure your firewall allows incoming connections to the port.

To require a username and password for the WebUI and API, enable cookie-session
authentication in `~/.airtype/config.toml`:

```toml
[webui.auth]
enabled = true
username = "airtype"
password = "change-me"
session_days = 14
```

After signing in, the browser stores an HttpOnly session token rather than the
password. Passwords saved from the Settings page are stored as PBKDF2 hashes.

To limit the WebUI to this machine only, bind it to localhost:

```bash
AIRTYPE_WEBUI_HOST=127.0.0.1 ./scripts/start-webui.sh
```

### Build macOS App

```bash
./scripts/build-localapp-macos.sh
open dist/AirType.app
```

Runtime user data is stored outside the app:

- config: `~/.airtype/config.toml`
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
| Start/Stop recording | Double-press **Right Ctrl** or **Right Option** |

Both hotkeys are always enabled, so no menu or config switch is needed.

## License

Private project.
