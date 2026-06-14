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
- microphone device menu with persisted device name
- microphone mode menu: `on_demand`, `always`
- hotkey menu: `right_ctrl`, `right_option`
- move lock
- floating recording dialog
- desktop-ratio dialog position persisted to `config.toml`
- configured right Ctrl or right Option double-press hotkey via Quartz event tap
- microphone recording through `AVAudioEngine`
- automatic local FastAPI WebUI startup when `[localapp.backend-endpoint].mode = "local"`
- `/api/transcribe/ime` multipart upload
- paste ASR text back into the previous app

## WebUI

When `[localapp.backend-endpoint].mode = "local"`, the SwiftUI frontend checks `/api/health`. If the WebUI is not already running, it starts:

```bash
.venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port 8003
```

The command runs from the project `source/webui/` directory. The Web UI reads `[webui.whisper-server]` from `config.toml` for the local `whisper-server` and model paths.

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
