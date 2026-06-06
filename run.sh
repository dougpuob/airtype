#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
DEFAULT_MODEL="$HOME/.airtype/models/ggml-large-v3-turbo-q5_0.bin"

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "AirType environment is not ready."
  echo
  echo "Run setup first:"
  echo "  ./scripts/setup.sh"
  exit 1
fi

if [[ ! -f "$ROOT_DIR/config.toml" ]]; then
  echo "config.toml is missing."
  echo
  echo "Run setup first:"
  echo "  ./scripts/setup.sh"
  exit 1
fi

eval "$("$PYTHON_BIN" - "$ROOT_DIR/config.toml" <<'PY'
import shlex
import sys
import tomllib
from pathlib import Path

with open(sys.argv[1], "rb") as config_file:
    config = tomllib.load(config_file)

whisper = config.get("whisper-local", {})

def emit(name, value):
    value = str(value or "")
    if value:
        print(f"{name}={shlex.quote(str(Path(value).expanduser()))}")

emit("CONFIG_WHISPER_BIN_DIR", whisper.get("whisper_bin_dir"))
emit("CONFIG_WHISPER_CPP_MODEL", whisper.get("model_path"))
PY
)"

if [[ -n "${CONFIG_WHISPER_BIN_DIR:-}" && -d "$CONFIG_WHISPER_BIN_DIR" ]]; then
  if [[ -x "$CONFIG_WHISPER_BIN_DIR/whisper-server" && -z "${WHISPER_CPP_SERVER_BIN:-}" ]]; then
    export WHISPER_CPP_SERVER_BIN="$CONFIG_WHISPER_BIN_DIR/whisper-server"
  fi
  if [[ -x "$CONFIG_WHISPER_BIN_DIR/whisper-cli" && -z "${WHISPER_CPP_BIN:-}" ]]; then
    export WHISPER_CPP_BIN="$CONFIG_WHISPER_BIN_DIR/whisper-cli"
  fi
fi

if [[ -n "${CONFIG_WHISPER_CPP_MODEL:-}" && -f "$CONFIG_WHISPER_CPP_MODEL" && -z "${WHISPER_CPP_MODEL:-}" ]]; then
  export WHISPER_CPP_MODEL="$CONFIG_WHISPER_CPP_MODEL"
fi

if [[ -f "$DEFAULT_MODEL" && -z "${WHISPER_CPP_MODEL:-}" ]]; then
  export WHISPER_CPP_MODEL="$DEFAULT_MODEL"
fi

exec "$PYTHON_BIN" "$ROOT_DIR/frontend/main.py"
