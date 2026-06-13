from __future__ import annotations

import os
import tomllib
from pathlib import Path
from typing import Any, Dict, Optional, Tuple


DEFAULT_APP_SETTINGS: Dict[str, Any] = {
    "whisper": {
        "model_dir": "",
        "model_filename": "",
        "server_bin": "",
        "endpoint": "",
        "language": "zh-tw",
        "beam": 5,
        "temperature": 0,
    },
    "llm": {
        "name": "default",
        "provider": "llama.cpp",
        "endpoint": "http://127.0.0.1:8080",
        "model": "",
        "models": [],
        "selected_model": "",
        "contextLength": 8192,
        "temperature": 0.4,
        "system": "Summarize and answer questions using the transcript as the source of truth.",
    },
}
DEFAULT_WEBUI_DATA_DIR = "~/.airtype/data"

WEBUI_SECTION_ALIASES = {
    "whisper": ("whisper-server", "whisper"),
    "llm": ("llm-server", "llm"),
}


def read_config(path: str | Path) -> Dict[str, Any]:
    config_path = Path(path)
    if not config_path.exists():
        return {}

    try:
        with config_path.open("rb") as config_file:
            loaded = tomllib.load(config_file)
    except (OSError, tomllib.TOMLDecodeError):
        return {}

    return loaded if isinstance(loaded, dict) else {}


def _select_default_llm(servers: list | None, default_name: str | None = None) -> dict | None:
    """Select the default LLM server from an array of server configs."""
    if not servers or not isinstance(servers, list):
        return None
    if default_name:
        for server in servers:
            if isinstance(server, dict) and server.get("name") == default_name:
                return server
    return servers[0] if servers else None


def read_webui_settings(path: str | Path) -> Dict[str, Any]:
    config = read_config(path)
    webui = config.get("webui", {})
    if not isinstance(webui, dict):
        return {}

    settings: Dict[str, Any] = {}
    for key, section_names in WEBUI_SECTION_ALIASES.items():
        # Try dict first
        value = next(
            (
                webui.get(section_name)
                for section_name in section_names
                if isinstance(webui.get(section_name), dict)
            ),
            None,
        )
        # Fall back to list for llm-server array
        if value is None and key == "llm":
            for section_name in section_names:
                if isinstance(webui.get(section_name), list):
                    value = webui.get(section_name)
                    break
        if isinstance(value, dict):
            settings[key] = value
        elif key == "llm" and isinstance(value, list):
            # Handle array format: select the default server
            default_name = webui.get("default-llm-server-name")
            selected = _select_default_llm(value, default_name)
            if selected and isinstance(selected, dict):
                settings[key] = selected
    return normalize_app_settings(settings) if settings else {}


def read_webui_data_dir(path: str | Path) -> str:
    config_path = Path(path)
    config = read_config(config_path)
    webui = config.get("webui", {})
    storage = webui.get("storage", {}) if isinstance(webui, dict) else {}
    configured = storage.get("data_dir") if isinstance(storage, dict) else None
    data_dir = str(configured or DEFAULT_WEBUI_DATA_DIR).strip() or DEFAULT_WEBUI_DATA_DIR
    expanded = Path(os.path.expanduser(data_dir))
    if not expanded.is_absolute():
        expanded = config_path.parent / expanded
    return str(expanded.resolve())


def normalize_app_settings(settings: Dict[str, Any]) -> Dict[str, Any]:
    normalized = dict(settings)

    if "whisperEndpoint" in normalized:
        legacy_model = normalized.pop("whisperModel", "")
        model_dir = ""
        model_filename = ""
        if legacy_model:
            model_path = os.path.expanduser(legacy_model)
            model_dir = os.path.dirname(model_path)
            model_filename = os.path.basename(model_path)
        normalized["whisper"] = {
            "endpoint": normalized.pop("whisperEndpoint", ""),
            "language": normalized.pop("whisperLanguage", "zh-tw"),
            "beam": normalized.pop("whisperBeam", 5),
            "temperature": normalized.pop("whisperTemperature", 0),
            "model_dir": model_dir,
            "model_filename": model_filename,
            "server_bin": normalized.pop("whisperServerBin", ""),
        }
    if "llmProvider" in normalized:
        legacy_llm_model = normalized.pop("llmModel", "")
        normalized["llm"] = {
            "provider": normalized.pop("llmProvider", "llama.cpp"),
            "endpoint": normalized.pop("llmEndpoint", "http://127.0.0.1:8080"),
            "model": legacy_llm_model,
            "selected_model": legacy_llm_model,
            "contextLength": normalized.pop("llmContextLength", 8192),
            "temperature": normalized.pop("llmTemperature", 0.4),
            "system": normalized.pop(
                "llmSystem",
                "Summarize and answer questions using the transcript as the source of truth.",
            ),
        }

    whisper = {**DEFAULT_APP_SETTINGS["whisper"], **_dict_value(normalized.get("whisper"))}
    model_dir, model_filename = split_whisper_model_settings(whisper)
    whisper["model_dir"] = model_dir
    whisper["model_filename"] = model_filename
    whisper.pop("model", None)
    whisper.pop("model_path", None)
    whisper["beam"] = _int_in_range(whisper.get("beam"), 5, minimum=1, maximum=16)
    whisper["temperature"] = _float_in_range(whisper.get("temperature"), 0, minimum=0, maximum=2)

    llm = {**DEFAULT_APP_SETTINGS["llm"], **_dict_value(normalized.get("llm"))}
    llm["models"] = _string_list(llm.get("models"))
    llm["selected_model"] = llm.get("selected_model") or llm.get("selected-model") or llm.get("default_model") or llm.get("model", "")
    if llm.get("selected_model"):
        llm["model"] = llm["selected_model"]
    llm["contextLength"] = _int_in_range(llm.get("contextLength"), 8192, minimum=1)
    llm["temperature"] = _float_in_range(llm.get("temperature"), 0.4, minimum=0, maximum=2)

    return {
        "whisper": whisper,
        "llm": llm,
    }


def remove_webui_sections(text: str) -> str:
    import re

    pattern = re.compile(
        r"(?ms)^(?:\[webui\]|\[{1,2}webui\.(?:whisper-server|llm-server|whisper|llm)\]{1,2})\n.*?(?=^\[|\Z)"
    )
    text = pattern.sub("", text)
    header_pattern = re.compile(
        r"(?m)^#=+\n# Web UI Settings\n#=+\n(?:\n|$)"
    )
    return header_pattern.sub("", text)


def render_webui_settings_toml(settings: Dict[str, Any]) -> str:
    normalized = normalize_app_settings(settings)
    whisper = normalized["whisper"]
    llm = normalized["llm"]
    lines = [
        "#===============================================================================",
        "# Web UI Settings",
        "#===============================================================================",
        "",
        "[webui.whisper-server]",
        f"model_dir = {_toml_string(whisper.get('model_dir', ''))}",
        f"model_filename = {_toml_string(whisper.get('model_filename', ''))}",
        f"server_bin = {_toml_string(whisper.get('server_bin', ''))}",
        f"endpoint = {_toml_string(whisper.get('endpoint', ''))}",
        f"language = {_toml_string(whisper.get('language', 'zh-tw'))}",
        f"beam = {_toml_number(whisper.get('beam', 5), 5)}",
        f"temperature = {_toml_number(whisper.get('temperature', 0), 0)}",
        "",
        "[[webui.llm-server]]",
        f'name = {_toml_string(llm.get("name", "default"))}',
        f"provider = {_toml_string(llm.get('provider', 'llama.cpp'))}",
        f"endpoint = {_toml_string(llm.get('endpoint', 'http://127.0.0.1:8080'))}",
        f"models = {_toml_string_array(llm.get('models', []))}",
        f"selected-model = {_toml_string(llm.get('selected_model', llm.get('model', '')))}",
        f"contextLength = {_toml_number(llm.get('contextLength', 8192), 8192)}",
        f"temperature = {_toml_number(llm.get('temperature', 0.4), 0.4)}",
        f"system = {_toml_string(llm.get('system', ''))}",
        "",
        "[webui]",
        f'default-llm-server-name = {_toml_string(llm.get("name", "default"))}',
    ]
    return "\n".join(lines)


def whisper_model_path_from_settings(whisper_settings: Dict[str, Any]) -> Optional[str]:
    model_dir = whisper_settings.get("model_dir")
    model_filename = whisper_settings.get("model_filename")
    if model_dir and model_filename:
        return os.path.join(os.path.expanduser(str(model_dir)), str(model_filename))

    legacy_model = whisper_settings.get("model") or whisper_settings.get("model_path")
    if legacy_model:
        return os.path.expanduser(str(legacy_model))
    return None


def split_whisper_model_settings(
    whisper_settings: Dict[str, Any],
    fallback_settings: Optional[Dict[str, Any]] = None,
) -> Tuple[str, str]:
    model_dir = whisper_settings.get("model_dir")
    model_filename = whisper_settings.get("model_filename")
    if model_dir or model_filename:
        return str(model_dir or ""), str(model_filename or "")

    legacy_model = whisper_settings.get("model") or whisper_settings.get("model_path")
    if legacy_model:
        model_path = os.path.expanduser(str(legacy_model))
        return os.path.dirname(model_path), os.path.basename(model_path)

    if fallback_settings:
        return split_whisper_model_settings(fallback_settings)

    return "", ""


def _dict_value(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [str(item) for item in value if str(item or "")]


def _int_in_range(value: Any, default_value: int, minimum: int, maximum: Optional[int] = None) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        number = default_value
    number = max(minimum, number)
    if maximum is not None:
        number = min(maximum, number)
    return number


def _float_in_range(
    value: Any,
    default_value: int | float,
    minimum: int | float,
    maximum: Optional[int | float] = None,
) -> int | float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        number = float(default_value)
    number = max(float(minimum), number)
    if maximum is not None:
        number = min(float(maximum), number)
    return int(number) if number.is_integer() else number


def _toml_string(value: Any) -> str:
    text = str(value or "")
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _toml_string_array(value: Any) -> str:
    return "[" + ", ".join(_toml_string(item) for item in _string_list(value)) + "]"


def _toml_number(value: Any, default_value: int | float) -> str:
    try:
        number = float(value)
    except (TypeError, ValueError):
        number = float(default_value)
    if number.is_integer():
        return str(int(number))
    return f"{number:.4f}".rstrip("0").rstrip(".")
