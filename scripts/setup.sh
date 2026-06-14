#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="$ROOT_DIR/.venv"
AIRTYPE_HOME="$HOME/.airtype"
CONFIG_PATH="$HOME/.airtype/config.toml"
MODEL_DIR="$AIRTYPE_HOME/models"
DEFAULT_WHISPER_MODEL_NAME="large-v3-turbo-q5_0"
DEFAULT_WHISPER_MODEL_FILE="ggml-${DEFAULT_WHISPER_MODEL_NAME}.bin"
DEFAULT_WHISPER_MODEL_PATH="$MODEL_DIR/$DEFAULT_WHISPER_MODEL_FILE"
DEFAULT_WHISPER_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$DEFAULT_WHISPER_MODEL_FILE"
UV_BIN="${UV_BIN:-}"
PYTHON_BIN="${PYTHON_BIN:-}"
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

ensure_uv_python() {
  if PYTHON_BIN="$("$UV_BIN" python find 3.11 2>/dev/null)"; then
    return
  fi

  echo
  echo "Python 3.11 was not found through uv."
  echo "Installing uv-managed Python 3.11..."
  "$UV_BIN" python install 3.11

  if ! PYTHON_BIN="$("$UV_BIN" python find 3.11 2>/dev/null)"; then
    echo "Python 3.11 was installed with uv, but setup could not find it."
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
    echo "whisper-server was not found."
    echo "Install whisper.cpp manually, or configure a remote WebUI in $CONFIG_PATH."
    return
  fi

  echo "whisper-server was not found."
  echo "Recommended install command:"
  echo "  brew install whisper-cpp"
  echo "Setup does not install Homebrew or whisper-cpp. Install it yourself, then run setup again."
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
  echo "Updating $CONFIG_PATH Web UI settings..."
  mkdir -p "$(dirname "$CONFIG_PATH")"
  "$VENV_DIR/bin/python" - "$CONFIG_PATH" "$DEFAULT_WHISPER_MODEL_PATH" "$WHISPER_BIN_DIR" "$ROOT_DIR/config.schema.json" <<'PY'
import json
import re
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
model_path, whisper_bin_dir, schema_path = sys.argv[2:5]
model = Path(model_path)
server_bin = str(Path(whisper_bin_dir) / "whisper-server")
schema = json.loads(Path(schema_path).read_text(encoding="utf-8"))

def toml_string(value):
    text = str(value or "")
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'

def toml_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(item) for item in value) + "]"
    return toml_string(value)

def object_defaults(object_schema):
    return {
        key: property_schema.get("default", "")
        for key, property_schema in object_schema.get("properties", {}).items()
    }

def remove_backend_sections(text):
    text = re.sub(r"(?ms)^\[{1,2}webui\.(?:whisper-server|llm-server|yt-dlp|ytdlp|whisper|llm)\]{1,2}\n.*?(?=^\[|\Z)", "", text)
    text = re.sub(r"(?ms)^\[webui\]\n.*?(?=^\[|\Z)", "", text)
    text = re.sub(r"(?m)^#=+\n# Web UI Settings\n#=+\n(?:\n|$)", "", text)
    return text.rstrip()

webui_schema = schema["properties"]["webui"]["properties"]
whisper_defaults = object_defaults(webui_schema["whisper-server"])
ytdlp_defaults = object_defaults(webui_schema["yt-dlp"])
llm_defaults = object_defaults(webui_schema["llm-server"]["items"])
default_llm_name = webui_schema["default-llm-server-name"].get("default", "")

model_dir = str(model.parent) if model.exists() else ""
model_filename = model.name if model.exists() else ""
server_bin_value = server_bin if Path(server_bin).exists() else ""
whisper_defaults.update({
    "model_dir": model_dir,
    "model_filename": model_filename,
    "server_bin": server_bin_value,
})
if not llm_defaults.get("name"):
    llm_defaults["name"] = "default"
if not default_llm_name:
    default_llm_name = llm_defaults["name"]

backend_text = "\n".join([
    "#===============================================================================",
    "# Web UI Settings",
    "#===============================================================================",
    "",
    "[webui.whisper-server]",
    *(f"{key} = {toml_value(whisper_defaults[key])}" for key in [
        "model_dir",
        "model_filename",
        "server_bin",
        "remote_endpoint",
        "server_args",
        "language",
        "beam",
        "temperature",
    ]),
    "",
    "[webui.yt-dlp]",
    *(f"{key} = {toml_value(ytdlp_defaults[key])}" for key in [
        "cookies",
        "cookies_from_browser",
    ]),
    "",
    "[[webui.llm-server]]",
    *(f"{key} = {toml_value(llm_defaults[key])}" for key in [
        "name",
        "provider",
        "endpoint",
        "models",
        "selected-model",
        "contextLength",
        "temperature",
        "system",
    ]),
    "",
    "[webui]",
    f"default-llm-server-name = {toml_string(default_llm_name)}",
])

try:
    text = config_path.read_text(encoding="utf-8")
except OSError:
    text = "# AirType user config\n"

text = remove_backend_sections(text)
config_path.write_text(f"{text}\n\n{backend_text}\n", encoding="utf-8")
print(f"Wrote {config_path}")
if model.exists():
    print(f"Configured Whisper model: {model_path}")
else:
    print("Model file was not found; Web UI settings kept without a local model path.")
if Path(server_bin).exists():
    print(f"Configured whisper-server: {server_bin}")
else:
    print("whisper-server was not found; Web UI settings kept without a local server_bin path.")
PY
}

ensure_config() {
  local config="$CONFIG_PATH"
  if [[ -f "$config" ]]; then
    echo "Config already exists: $config"
    return
  fi

  mkdir -p "$(dirname "$config")"
  echo "Config does not exist: $config"
  echo "Generating default config from schema: $ROOT_DIR/config.schema.json"
  "$VENV_DIR/bin/python" "$ROOT_DIR/scripts/generate-config-from-schema.py" \
    "$config" \
    "$ROOT_DIR/config.schema.json" \
    "scripts/setup.sh"
}

echo "AirType setup"
echo
echo "This script checks system prerequisites, prepares the project .venv, and creates project config."
echo "It does not install uv, Homebrew, whisper-cpp, or ffmpeg."
echo "It may install uv-managed Python 3.11 and Python packages into this project's .venv."
echo
echo "Planned actions:"
echo "  1. Check for uv"
echo "  2. Ensure Python 3.11 is available through uv"
echo "  3. Check for ffmpeg"
echo "  4. Create or reuse .venv"
echo "  5. Install WebUI Python dependencies into .venv"
echo "     - fastapi, uvicorn, python-multipart, pydantic"
echo "     - yt-dlp, opencc-python-reimplemented"
echo "  6. Create $CONFIG_PATH from config.schema.json defaults if it does not exist"
echo "  7. Check for whisper.cpp command-line tools"
echo "  8. Offer to download the default Whisper model"
echo "     - $DEFAULT_WHISPER_MODEL_FILE"
echo "     - stored in $MODEL_DIR"
echo "  9. Update $CONFIG_PATH Web UI settings to use the downloaded model"
echo
if ! confirm "Continue with setup?"; then
  echo "Setup cancelled."
  exit 0
fi

if ! find_uv; then
  echo
  echo "uv is not installed or not in PATH."
  echo "Install uv by following README.md, then run ./scripts/setup.sh again."
  exit 1
fi

echo
echo "Using uv: $UV_BIN"

ensure_uv_python

PYTHON_VERSION="$("$PYTHON_BIN" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
if ! "$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)'; then
  echo
  echo "Python 3.11+ is required. Found Python $PYTHON_VERSION."
  echo "Install Python 3.11 with uv by following README.md, then run ./scripts/setup.sh again."
  exit 1
fi

echo
echo "Using Python: $PYTHON_BIN ($PYTHON_VERSION)"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo
  echo "Missing required command-line tool: ffmpeg"
  echo "Install it by following README.md, then run ./scripts/setup.sh again."
  exit 1
fi

echo
if [[ -x "$VENV_DIR/bin/python" ]]; then
  echo "Reusing virtual environment: .venv"
else
  echo "Creating virtual environment: .venv"
  "$UV_BIN" venv --python "$PYTHON_BIN" "$VENV_DIR"
fi

echo
echo "Installing WebUI Python dependencies into .venv..."
"$UV_BIN" pip install --python "$VENV_DIR/bin/python" -r "$ROOT_DIR/source/webui/requirements.txt"

if ! "$VENV_DIR/bin/python" -c 'import fastapi, uvicorn, multipart, pydantic, yt_dlp, opencc' >/dev/null 2>&1; then
  echo
  echo "WebUI Python dependencies were not installed correctly in .venv."
  exit 1
fi

echo "Found WebUI Python dependencies in .venv."

echo
echo "Checking config..."
ensure_config

ensure_whisper_cpp
download_whisper_model
write_backend_settings

echo
echo "Setup complete."
echo "Build & Run AirType with:"
echo "  ./scripts/build-localapp-macos.sh"
echo "  open dist/AirType.app"
