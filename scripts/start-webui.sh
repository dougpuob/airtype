#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEBUI_DIR="$ROOT_DIR/source/webui"
CONFIG_PATH="$HOME/.airtype/config.toml"
VENV_PYTHON="$ROOT_DIR/.venv/bin/python"
UV_BIN="${UV_BIN:-}"

AIRTYPE_WEBUI_PORT="${AIRTYPE_WEBUI_PORT:-8003}"

if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "AirType config file is missing:"
    echo "  $CONFIG_PATH"
    echo
    echo "Run setup to create it:"
    echo "  ./scripts/setup.sh"
    exit 1
fi

echo "Checking port $AIRTYPE_WEBUI_PORT..."

if lsof -nP -iTCP:$AIRTYPE_WEBUI_PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Port $AIRTYPE_WEBUI_PORT is already in use:"
    lsof -nP -iTCP:$AIRTYPE_WEBUI_PORT -sTCP:LISTEN
    echo
    echo "Stop the process above, or run with another port:"
    echo "  AIRTYPE_WEBUI_PORT=8004 $0"
    exit 1
fi

cd "$WEBUI_DIR"

if [[ ! -x "$VENV_PYTHON" ]]; then
    echo "AirType virtual environment is missing:"
    echo "  $ROOT_DIR/.venv"
    echo
    echo "Run setup to create it:"
    echo "  ./scripts/setup.sh"
    exit 1
fi

if [[ -z "$UV_BIN" ]]; then
    UV_BIN="$(command -v uv || true)"
fi

if [[ -z "$UV_BIN" ]]; then
    echo "uv is not installed or not in PATH."
    echo
    echo "Install uv by following README.md, then run setup again:"
    echo "  ./scripts/setup.sh"
    exit 1
fi

"$UV_BIN" pip install --python "$VENV_PYTHON" -r "$WEBUI_DIR/requirements.txt"

# Start the WebUI server using the virtual environment's Python
"$VENV_PYTHON" -m uvicorn app.main:app \
    --host 127.0.0.1 \
    --port "$AIRTYPE_WEBUI_PORT" \
    --reload
