#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEBUI_DIR="$ROOT_DIR/source/webui"

PORT="${PORT:-8003}"

echo "Checking port $PORT..."

if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Port $PORT is already in use:"
    lsof -nP -iTCP:$PORT -sTCP:LISTEN
    echo
    echo "Stop the process above, or run with another port:"
    echo "  PORT=8004 $0"
    exit 1
fi

cd "$WEBUI_DIR"

# Install dependencies using the virtual environment
"$ROOT_DIR/.venv/bin/pip" install -r "$WEBUI_DIR/requirements.txt"

# Start the WebUI server using the virtual environment's Python
"$ROOT_DIR/.venv/bin/python" -m uvicorn app.main:app \
    --host 127.0.0.1 \
    --port "$PORT" \
    --reload
