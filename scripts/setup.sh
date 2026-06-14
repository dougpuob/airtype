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
    echo "Install whisper.cpp manually, or configure a remote WebUI in config.toml."
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
    echo "AirType may need [webui.whisper-server].server_bin configured manually in config.toml."
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
  echo "Updating config.toml Web UI settings..."
  "$VENV_DIR/bin/python" - "$ROOT_DIR/config.toml" "$DEFAULT_WHISPER_MODEL_PATH" "$WHISPER_BIN_DIR" <<'PY'
import re
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
model_path, whisper_bin_dir = sys.argv[2:4]
model = Path(model_path)
server_bin = str(Path(whisper_bin_dir) / "whisper-server")

def toml_string(value):
    text = str(value or "")
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'

def remove_backend_sections(text):
    text = re.sub(r"(?ms)^\[{1,2}webui\.(?:whisper-server|llm-server|whisper|llm)\]{1,2}\n.*?(?=^\[|\Z)", "", text)
    text = re.sub(r"(?m)^\[webui\]\n.*?(?=^\[|\Z)", "", text)
    text = re.sub(r"(?m)^#=+\n# Web UI Settings\n#=+\n(?:\n|$)", "", text)
    return text.rstrip()

model_dir = str(model.parent) if model.exists() else ""
model_filename = model.name if model.exists() else ""
server_bin_value = server_bin if Path(server_bin).exists() else ""
backend_text = "\n".join([
    "#===============================================================================",
    "# Web UI Settings",
    "#===============================================================================",
    "",
    "[webui.whisper-server]",
    f"model_dir = {toml_string(model_dir)}",
    f"model_filename = {toml_string(model_filename)}",
    f"server_bin = {toml_string(server_bin_value)}",
    'endpoint = ""',
    'language = "zh-tw"',
    "beam = 5",
    "temperature = 0",
    "",
    "[[webui.llm-server]]",
    'name = "default"',
    'provider = "llama.cpp"',
    'endpoint = "http://127.0.0.1:8080"',
    'model = ""',
    "contextLength = 8192",
    "temperature = 0.4",
    'system = ""',
    "",
    "[webui]",
    'default-llm-server-name = "default"',
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
  local config="$ROOT_DIR/config.toml"
  if [[ -f "$config" ]]; then
    echo "Config already exists: config.toml"
    return
  fi

  cp "$ROOT_DIR/config.example.toml" "$config"
  echo "Created config.toml from config.example.toml"
}

echo "AirType setup"
echo
echo "This script will prepare the local Python environment with uv."
echo
echo "Planned actions:"
echo "  1. Check for uv, and offer to install it if missing"
echo "  2. Ensure Python 3.11 is available through uv"
echo "  3. Create or reuse .venv"
echo "  4. Install WebUI dependencies from source/webui/requirements.txt"
echo "     - fastapi, uvicorn, python-multipart, pydantic"
echo "     - yt-dlp, opencc-python-reimplemented"
echo "  5. Create config.toml if it does not exist"
echo "  6. Offer to install whisper-cpp with Homebrew on macOS"
echo "  7. Offer to download the default Whisper model"
echo "     - $DEFAULT_WHISPER_MODEL_FILE"
echo "     - stored in $MODEL_DIR"
echo "  8. Update config.toml Web UI settings to use the downloaded model"
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
echo "Installing WebUI dependencies..."
"$UV_BIN" pip install --python "$VENV_DIR/bin/python" -r "$ROOT_DIR/source/webui/requirements.txt"

echo
echo "Checking config..."
ensure_config

ensure_whisper_cpp
download_whisper_model
write_backend_settings

echo
echo "Setup complete."
echo "Run AirType with:"
echo "  ./run.sh"
