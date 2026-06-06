#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="$ROOT_DIR/.venv"
AIRTYPE_HOME="$HOME/.airtype"
MODEL_DIR="$AIRTYPE_HOME/models"
DEFAULT_WHISPER_MODEL_NAME="large-v3-turbo-q5_0"
DEFAULT_WHISPER_MODEL_FILE="ggml-${DEFAULT_WHISPER_MODEL_NAME}.bin"
DEFAULT_WHISPER_MODEL_PATH="$MODEL_DIR/$DEFAULT_WHISPER_MODEL_FILE"
DEFAULT_WHISPER_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$DEFAULT_WHISPER_MODEL_FILE"
UV_BIN="${UV_BIN:-}"
WHISPER_BIN_DIR="/opt/homebrew/bin"

confirm() {
  local prompt="$1"
  local answer
  read -r -p "$prompt [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

find_uv() {
  if [[ -n "$UV_BIN" && -x "$UV_BIN" ]]; then
    return 0
  fi

  if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
    return 0
  fi

  for candidate in "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv"; do
    if [[ -x "$candidate" ]]; then
      UV_BIN="$candidate"
      export PATH="$(dirname "$candidate"):$PATH"
      return 0
    fi
  done

  return 1
}

install_uv() {
  echo
  echo "uv is not installed."
  echo "Installer command:"
  echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"
  echo
  if ! confirm "Install uv now?"; then
    echo "Setup stopped. Install uv first, then run ./scripts/setup.sh again."
    exit 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to install uv. Please install curl and run ./scripts/setup.sh again."
    exit 1
  fi

  curl -LsSf https://astral.sh/uv/install.sh | sh
  if ! find_uv; then
    echo "uv was installed, but setup could not find it in PATH."
    echo "Open a new terminal or add ~/.local/bin to PATH, then run ./scripts/setup.sh again."
    exit 1
  fi
}

ensure_whisper_cpp() {
  echo
  echo "Checking whisper.cpp command-line tools..."
  if command -v whisper-server >/dev/null 2>&1; then
    local server_bin
    server_bin="$(command -v whisper-server)"
    WHISPER_BIN_DIR="$(dirname "$server_bin")"
    echo "Found whisper-server: $server_bin"
    if command -v whisper-cli >/dev/null 2>&1; then
      echo "Found whisper-cli: $(command -v whisper-cli)"
    fi
    return
  fi

  if command -v whisper-cli >/dev/null 2>&1; then
    local cli_bin
    cli_bin="$(command -v whisper-cli)"
    WHISPER_BIN_DIR="$(dirname "$cli_bin")"
    echo "Found whisper-cli: $cli_bin"
    echo "Note: AirType prefers whisper-server for local transcription."
  fi

  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Automatic whisper-cpp installation is currently only configured for macOS/Homebrew."
    echo "Install whisper.cpp manually, or configure a remote backend in config.toml."
    return
  fi

  echo "whisper-server was not found."
  echo "Recommended install command:"
  echo "  brew install whisper-cpp"
  echo
  if ! confirm "Install whisper-cpp with Homebrew now?"; then
    echo "Skipping whisper-cpp installation."
    return
  fi

  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is not installed or not in PATH."
    echo "Install Homebrew from https://brew.sh, then run ./scripts/setup.sh again."
    return
  fi

  echo "Installing whisper-cpp..."
  brew install whisper-cpp

  if command -v whisper-server >/dev/null 2>&1; then
    local server_bin
    server_bin="$(command -v whisper-server)"
    WHISPER_BIN_DIR="$(dirname "$server_bin")"
    echo "whisper-server is ready: $server_bin"
  else
    echo "whisper-cpp installed, but whisper-server was not found in PATH."
    echo "AirType may need whisper_bin_dir configured manually in config.toml."
  fi
}

download_whisper_model() {
  echo
  echo "Checking Whisper model..."
  echo "Default model: $DEFAULT_WHISPER_MODEL_NAME"
  echo "Destination: $DEFAULT_WHISPER_MODEL_PATH"
  echo "Source: $DEFAULT_WHISPER_MODEL_URL"
  echo

  mkdir -p "$MODEL_DIR"

  if [[ -f "$DEFAULT_WHISPER_MODEL_PATH" ]]; then
    echo "Model already exists: $DEFAULT_WHISPER_MODEL_PATH"
    return
  fi

  echo "This model is large and may take several minutes to download."
  if ! confirm "Download $DEFAULT_WHISPER_MODEL_FILE now?"; then
    echo "Skipping model download."
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to download the model. Please install curl and run ./scripts/setup.sh again."
    return
  fi

  local temp_path="$DEFAULT_WHISPER_MODEL_PATH.partial"
  rm -f "$temp_path"
  echo "Downloading Whisper model with progress..."
  curl -L --fail --progress-bar "$DEFAULT_WHISPER_MODEL_URL" -o "$temp_path"
  mv "$temp_path" "$DEFAULT_WHISPER_MODEL_PATH"
  echo "Downloaded model: $DEFAULT_WHISPER_MODEL_PATH"
}

write_backend_settings() {
  echo
  echo "Updating backend/settings.json..."
  "$VENV_DIR/bin/python" - "$ROOT_DIR/backend/settings.json" "$DEFAULT_WHISPER_MODEL_PATH" <<'PY'
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
model_path = sys.argv[2]

default = {
    "whisper": {
        "model": "",
        "endpoint": "",
        "language": "zh-tw",
        "beam": 5,
        "temperature": 0,
    },
    "llm": {
        "provider": "llama.cpp",
        "endpoint": "http://127.0.0.1:8080",
        "model": "",
        "contextLength": 8192,
        "temperature": 0.4,
        "system": "",
    },
}

try:
    current = json.loads(settings_path.read_text(encoding="utf-8"))
    if not isinstance(current, dict):
        current = {}
except Exception:
    current = {}

merged = default | {key: value for key, value in current.items() if isinstance(value, dict)}
merged["whisper"] = default["whisper"] | current.get("whisper", {})
merged["llm"] = default["llm"] | current.get("llm", {})
if Path(model_path).exists():
    merged["whisper"]["model"] = model_path
    merged["whisper"]["endpoint"] = ""

settings_path.write_text(json.dumps(merged, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"Wrote {settings_path}")
if Path(model_path).exists():
    print(f"Configured Whisper model: {model_path}")
else:
    print("Model file was not found; backend settings kept without a local model path.")
PY
}

write_airtype_config() {
  echo
  echo "Updating config.toml whisper-local section..."
  "$VENV_DIR/bin/python" - "$ROOT_DIR/config.toml" "$WHISPER_BIN_DIR" "$DEFAULT_WHISPER_MODEL_PATH" <<'PY'
import sys
import tomllib
from pathlib import Path

config_path = Path(sys.argv[1])
whisper_bin_dir, model_path = sys.argv[2:4]

default = {
    "chinese-mode": {"mode": "zh-tw"},
    "backend": {
        "mode": "local",
        "local_endpoint": "http://localhost:8003",
        "remote_endpoint": "",
    },
    "microphone": {"selected_order": ""},
    "floating-dialog": {
        "position_x_ratio": 0.5,
        "position_y_ratio": 0.62,
        "move_lock": True,
    },
    "whisper-local": {
        "whisper_bin_dir": "/opt/homebrew/bin",
        "model_path": "~/.airtype/models/ggml-large-v3-turbo-q5_0.bin",
    },
}

try:
    current = tomllib.loads(config_path.read_text(encoding="utf-8"))
    if not isinstance(current, dict):
        current = {}
except Exception:
    current = {}

merged = {}
for section, values in default.items():
    merged[section] = dict(values)
    existing = current.get(section)
    if isinstance(existing, dict):
        merged[section].update(existing)

merged["whisper-local"].update(
    {
        "whisper_bin_dir": whisper_bin_dir,
        "model_path": model_path,
    }
)

def toml_string(value):
    text = str(value)
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'

def toml_float(value, default_value):
    try:
        number = float(value)
    except (TypeError, ValueError):
        number = default_value
    return f"{number:.4f}".rstrip("0").rstrip(".")

def toml_bool(value):
    return "true" if bool(value) else "false"

text = "\n".join(
    [
        "# AirType user config",
        "",
        "[chinese-mode]",
        '# Options: "zh-tw", "zh-cn"',
        f"mode = {toml_string(merged['chinese-mode'].get('mode', 'zh-tw'))}",
        "",
        "[backend]",
        '# Options: "local", "remote"',
        f"mode = {toml_string(merged['backend'].get('mode', 'local'))}",
        f"local_endpoint = {toml_string(merged['backend'].get('local_endpoint', 'http://localhost:8003'))}",
        f"remote_endpoint = {toml_string(merged['backend'].get('remote_endpoint', ''))}",
        "",
        "[microphone]",
        "# Leave empty to use the system default microphone.",
        f"selected_order = {toml_string(merged['microphone'].get('selected_order', ''))}",
        "",
        "[floating-dialog]",
        "# Position is stored as the dialog center ratio across the whole desktop.",
        f"position_x_ratio = {toml_float(merged['floating-dialog'].get('position_x_ratio'), 0.5)}",
        f"position_y_ratio = {toml_float(merged['floating-dialog'].get('position_y_ratio'), 0.62)}",
        f"move_lock = {toml_bool(merged['floating-dialog'].get('move_lock', True))}",
        "",
        "[whisper-local]",
        "# Local whisper.cpp runtime and model locations.",
        f"whisper_bin_dir = {toml_string(merged['whisper-local'].get('whisper_bin_dir', '/opt/homebrew/bin'))}",
        f"model_path = {toml_string(merged['whisper-local'].get('model_path', '~/.airtype/models/ggml-large-v3-turbo-q5_0.bin'))}",
        "",
    ]
)
config_path.write_text(text, encoding="utf-8")
print(f"Wrote {config_path}")
PY
}

ensure_config() {
  local config="$ROOT_DIR/config.toml"
  if [[ -f "$config" ]]; then
    echo "Config already exists: config.toml"
    return
  fi

  cat > "$config" <<'CONFIG'
# AirType user config

[chinese-mode]
# Options: "zh-tw", "zh-cn"
mode = "zh-tw"

[backend]
# Options: "local", "remote"
mode = "local"
local_endpoint = "http://localhost:8003"
remote_endpoint = ""

[microphone]
# Leave empty to use the system default microphone.
selected_order = ""

[floating-dialog]
# Position is stored as the dialog center ratio across the whole desktop.
position_x_ratio = 0.5
position_y_ratio = 0.62
move_lock = true

[whisper-local]
# Local whisper.cpp runtime and model locations.
whisper_bin_dir = "/opt/homebrew/bin"
model_path = "~/.airtype/models/ggml-large-v3-turbo-q5_0.bin"
CONFIG
  echo "Created config.toml"
}

echo "AirType setup"
echo
echo "This script will prepare the local Python environment with uv."
echo
echo "Planned actions:"
echo "  1. Check for uv, and offer to install it if missing"
echo "  2. Ensure Python 3.11 is available through uv"
echo "  3. Create or reuse .venv"
echo "  4. Install frontend dependencies from frontend/pyproject.toml"
echo "     - PySide6"
echo "     - pynput"
echo "  5. Install backend dependencies from backend/requirements.txt"
echo "     - fastapi, uvicorn, python-multipart, pydantic"
echo "     - openai-whisper, torch, torchaudio"
echo "     - yt-dlp, opencc-python-reimplemented"
echo "  6. Create config.toml if it does not exist"
echo "  7. Offer to install whisper-cpp with Homebrew on macOS"
echo "  8. Offer to download the default Whisper model"
echo "     - $DEFAULT_WHISPER_MODEL_FILE"
echo "     - stored in $MODEL_DIR"
echo "  9. Update backend/settings.json to use the downloaded model"
echo
if ! confirm "Continue with setup?"; then
  echo "Setup cancelled."
  exit 0
fi

if ! find_uv; then
  install_uv
fi

echo
echo "Using uv: $UV_BIN"
echo
echo "Ensuring Python 3.11 is available..."
"$UV_BIN" python install 3.11

echo
echo "Creating virtual environment: .venv"
"$UV_BIN" venv --python 3.11 "$VENV_DIR"

echo
echo "Installing frontend dependencies..."
"$UV_BIN" pip install --python "$VENV_DIR/bin/python" -e "$ROOT_DIR/frontend"

echo
echo "Installing backend dependencies..."
"$UV_BIN" pip install --python "$VENV_DIR/bin/python" -r "$ROOT_DIR/backend/requirements.txt"

echo
echo "Checking config..."
ensure_config

ensure_whisper_cpp
download_whisper_model
write_backend_settings
write_airtype_config

echo
echo "Setup complete."
echo "Run AirType with:"
echo "  ./run.sh"
