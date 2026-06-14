#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print("Usage: generate-config-from-schema.py CONFIG_PATH SCHEMA_PATH [GENERATOR_NAME]", file=sys.stderr)
        return 2

    repo_root = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(repo_root / "source" / "webui"))

    from app.config_schema import ensure_config_exists

    config_path = Path(sys.argv[1]).expanduser()
    schema_path = Path(sys.argv[2])
    generator_name = sys.argv[3] if len(sys.argv) == 4 else "generate-config-from-schema.py"
    created = not config_path.exists()
    ensure_config_exists(config_path, schema_path=schema_path, generator_name=generator_name)
    if created:
        print(f"Created {config_path} from {schema_path}")
    else:
        print(f"Config already exists: {config_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
