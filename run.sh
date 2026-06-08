#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -x "$ROOT_DIR/.venv/bin/python" ]]; then
  echo "AirType environment is not ready."
  echo
  echo "Run setup first:"
  echo "  ./scripts/setup.sh"
  exit 1
fi

if [[ ! -f "$ROOT_DIR/config.toml" ]]; then
  echo "config.toml is missing."
  echo
  echo "Create one from the example:"
  echo "  cp config.example.toml config.toml"
  echo
  echo "Run setup first:"
  echo "  ./scripts/setup.sh"
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is not available."
  echo
  echo "Install Xcode or Xcode Command Line Tools first:"
  echo "  xcode-select --install"
  exit 1
fi

cd "$ROOT_DIR/source/localapp/macos"
exec swift run AirTypeMac
