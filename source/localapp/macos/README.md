# AirType macOS SwiftUI Frontend

Native SwiftUI menu bar frontend for AirType.

## Run

```bash
cd source/localapp/macos
swift run AirTypeMac
```

## Implemented

- menu bar app
- Chinese mode menu: `zh-tw`, `zh-cn`
- microphone device menu with system device order
- microphone mode menu: `on_demand`, `always`
- move lock
- floating recording dialog
- desktop-ratio dialog position persisted to `config.toml`
- right Ctrl double-press hotkey via Quartz event tap
- microphone recording through `AVAudioEngine`
- automatic local FastAPI backend startup when `[frontend.backend-endpoint].mode = "local"`
- `/api/transcribe/ime` multipart upload
- paste ASR text back into the previous app

## Backend

When `[frontend.backend-endpoint].mode = "local"`, the SwiftUI frontend checks `/api/health`. If the backend is not already running, it starts:

```bash
.venv/bin/python -m uvicorn app.main:app --host localhost --port 8003
```

The command runs from the project `source/webui/` directory. The backend reads `[backend.whisper-server]` from `config.toml` for the local `whisper-server` and model paths.

## Config

The app reads `config.toml` from the current project root when launched there. If not found, it falls back to:

```text
~/.airtype/config.toml
```

You can also override the path:

```bash
AIRTYPE_CONFIG_PATH=/path/to/config.toml swift run AirTypeMac
```

## macOS Permissions

Allow the app or Terminal in:

- System Settings > Privacy & Security > Accessibility
- System Settings > Privacy & Security > Microphone

## Logs

```bash
tail -n 80 ~/.airtype/airtype-macos.log
```
