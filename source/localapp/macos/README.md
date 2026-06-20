# AirType macOS SwiftUI Frontend

Native SwiftUI menu bar frontend for AirType.

## Run

```bash
./scripts/build-localapp-macos.sh
open dist/AirType.app
```

Run these commands from the project root.

## Implemented

- menu bar app
- Chinese mode menu: `zh-tw`, `zh-cn`
- microphone device menu with persisted device name
- microphone mode menu: `on_demand`, `always`
- move lock
- floating recording dialog
- desktop-ratio dialog position persisted to `~/.airtype/config.toml`
- right Ctrl and right Option double-press hotkeys via Quartz event tap
- microphone recording through `AVAudioEngine`
- automatic local FastAPI WebUI startup when `[localapp.backend-endpoint].mode = "local"`
- `/api/transcribe/ime` multipart upload
- paste ASR text back into the previous app

## WebUI

When `[localapp.backend-endpoint].mode = "local"`, the SwiftUI frontend checks `/api/health`. If the WebUI is not already running, it starts:

```bash
.venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port 8003
```

The command runs from the project `source/webui/` directory. The Web UI reads `[webui.whisper-server]` from `~/.airtype/config.toml` for the local `whisper-server` and model paths.

## Config

The app reads one config file:

```text
~/.airtype/config.toml
```

If that file does not exist, AirType shows an error and exits. Run `./scripts/setup.sh` from the project root to create it.

## macOS Permissions

Allow the app or Terminal in:

- System Settings > Privacy & Security > Accessibility
- System Settings > Privacy & Security > Microphone

## Logs

```bash
tail -n 80 ~/.airtype/airtype-localapp.log
tail -n 80 ~/.airtype/airtype-webui.log
```
