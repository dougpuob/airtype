from __future__ import annotations

import json
import os
import tomllib
from pathlib import Path
from typing import Any, Dict, Optional, Tuple


DEFAULT_APP_SETTINGS: Dict[str, Any] = {
    "whisper": {
        "model_dir": "",
        "model_filename": "",
        "server_bin": "",
        "remote_endpoint": "",
        "server_args": "",
        "language": "zh-tw",
        "beam": 5,
        "temperature": 0,
    },
    "llm": {
        "name": "default",
        "provider": "llama.cpp",
        "endpoint": "http://127.0.0.1:8080",
        "api_key": "",
        "model": "",
        "models": [],
        "selected_model": "",
        "contextLength": 8192,
        "temperature": 0.4,
        "system": "Summarize and answer questions using the transcript as the source of truth.",
        "disable_thinking": False,
    },
    "ytdlp": {
        "cookies": "",
        "cookies_from_browser": "",
    },
    "obsidian": {
        "vault_name": "",
        "default_folder": "",
    },
    "auth": {
        "enabled": False,
        "username": "airtype",
        "password": "",
    },
}
DEFAULT_WEBUI_DATA_DIR = "~/.airtype/data"
DEFAULT_CONFIG_SCHEMA_PATH = Path(__file__).resolve().parents[3] / "config.schema.json"

WEBUI_SECTION_ALIASES = {
    "whisper": ("whisper-server",),
    "llm": ("llm-server",),
    "ytdlp": ("yt-dlp", "ytdlp"),
    "obsidian": ("obsidian",),
    "auth": ("auth",),
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


def ensure_config_exists(
    path: str | Path,
    schema_path: str | Path = DEFAULT_CONFIG_SCHEMA_PATH,
    generator_name: str = "webui",
) -> Path:
    config_path = Path(path).expanduser().resolve()
    if config_path.exists():
        return config_path

    schema_file = Path(schema_path)
    schema = json.loads(schema_file.read_text(encoding="utf-8"))
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(_render_schema_defaults_toml(schema, generator_name), encoding="utf-8")
    return config_path


def _render_schema_defaults_toml(schema: Dict[str, Any], generator_name: str) -> str:
    lines = [
        "# AirType user config",
        "#:schema ./config.schema.json",
        f"# Generated from config.schema.json defaults by {generator_name}.",
        "",
    ]

    top_properties = schema.get("properties", {})
    localapp = top_properties.get("localapp", {})
    if localapp:
        lines.extend(
            [
                "#===============================================================================",
                "# Local App Settings",
                "#===============================================================================",
            ]
        )
        _emit_child_sections(lines, "localapp", localapp)
        lines.append("")

    webui = top_properties.get("webui", {})
    if webui:
        lines.extend(
            [
                "#===============================================================================",
                "# Web UI Settings",
                "#===============================================================================",
            ]
        )
        _emit_object_section(lines, "webui", webui)
        _emit_child_sections(lines, "webui", webui)

    return "\n".join(lines).rstrip() + "\n"


def _emit_object_section(lines: list[str], section_name: str, object_schema: Dict[str, Any]) -> None:
    lines.append(f"[{section_name}]")
    for key, property_schema in object_schema.get("properties", {}).items():
        if property_schema.get("type") in ("object", "array"):
            continue
        lines.append(f"{key} = {_toml_value(_default_for_schema_property(property_schema))}")


def _emit_child_sections(lines: list[str], parent_name: str, object_schema: Dict[str, Any]) -> None:
    for key, property_schema in object_schema.get("properties", {}).items():
        section_name = f"{parent_name}.{key}"
        property_type = property_schema.get("type")
        if property_type == "object":
            lines.append("")
            _emit_object_section(lines, section_name, property_schema)
        elif property_type == "array":
            item_schema = property_schema.get("items", {})
            lines.append("")
            lines.append(f"[[{section_name}]]")
            for item_key, item_property_schema in item_schema.get("properties", {}).items():
                lines.append(f"{item_key} = {_toml_value(_default_for_schema_property(item_property_schema))}")


def _default_for_schema_property(property_schema: Dict[str, Any]) -> Any:
    if "default" in property_schema:
        return property_schema["default"]
    if property_schema.get("type") == "array":
        return []
    return ""


def _toml_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, list):
        return "[" + ", ".join(_toml_value(item) for item in value) + "]"
    return _toml_string(value)


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

    whisper = {**DEFAULT_APP_SETTINGS["whisper"], **_dict_value(normalized.get("whisper"))}
    whisper["remote_endpoint"] = str(whisper.get("remote_endpoint") or "")
    model_dir, model_filename = split_whisper_model_settings(whisper)
    whisper["model_dir"] = model_dir
    whisper["model_filename"] = model_filename
    whisper["server_args"] = str(whisper.get("server_args") or "")
    whisper["beam"] = _int_in_range(whisper.get("beam"), 5, minimum=1, maximum=16)
    whisper["temperature"] = _float_in_range(whisper.get("temperature"), 0, minimum=0, maximum=2)

    llm = {**DEFAULT_APP_SETTINGS["llm"], **_dict_value(normalized.get("llm"))}
    llm["api_key"] = str(llm.get("api_key") or llm.get("api-key") or "")
    llm["models"] = _string_list(llm.get("models"))
    llm["selected_model"] = llm.get("selected_model") or llm.get("selected-model") or llm.get("default_model") or llm.get("model", "")
    if llm.get("selected_model"):
        llm["model"] = llm["selected_model"]
    llm["contextLength"] = _int_in_range(llm.get("contextLength"), 8192, minimum=1)
    llm["temperature"] = _float_in_range(llm.get("temperature"), 0.4, minimum=0, maximum=2)
    llm["disable_thinking"] = bool(llm.get("disable_thinking") or llm.get("disable-thinking"))

    ytdlp = {**DEFAULT_APP_SETTINGS["ytdlp"], **_dict_value(normalized.get("ytdlp"))}
    ytdlp["cookies"] = str(ytdlp.get("cookies") or "")
    ytdlp["cookies_from_browser"] = str(
        ytdlp.get("cookies_from_browser")
        or ytdlp.get("cookies-from-browser")
        or ""
    )

    obsidian = {**DEFAULT_APP_SETTINGS["obsidian"], **_dict_value(normalized.get("obsidian"))}
    obsidian["vault_name"] = str(
        obsidian.get("vault_name")
        or obsidian.get("vault-name")
        or ""
    ).strip()
    obsidian["default_folder"] = str(
        obsidian.get("default_folder")
        or obsidian.get("default-folder")
        or ""
    ).strip().strip("/")

    auth = {**DEFAULT_APP_SETTINGS["auth"], **_dict_value(normalized.get("auth"))}
    auth["enabled"] = bool(auth.get("enabled"))
    auth["username"] = str(auth.get("username") or "airtype")
    auth["password"] = str(auth.get("password") or "")

    return {
        "whisper": whisper,
        "llm": llm,
        "ytdlp": ytdlp,
        "obsidian": obsidian,
        "auth": auth,
    }


def remove_webui_sections(text: str) -> str:
    import re

    pattern = re.compile(
        r"(?ms)^(?:\[webui\]|\[{1,2}webui\.(?:auth|whisper-server|llm-server|yt-dlp|ytdlp|obsidian)\]{1,2})\n.*?(?=^\[|\Z)"
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
    ytdlp = normalized["ytdlp"]
    obsidian = normalized["obsidian"]
    auth = normalized["auth"]
    lines = [
        "#===============================================================================",
        "# Web UI Settings",
        "#===============================================================================",
        "",
        "[webui.whisper-server]",
        f"model_dir = {_toml_string(whisper.get('model_dir', ''))}",
        f"model_filename = {_toml_string(whisper.get('model_filename', ''))}",
        f"server_bin = {_toml_string(whisper.get('server_bin', ''))}",
        f"remote_endpoint = {_toml_string(whisper.get('remote_endpoint', ''))}",
        f"server_args = {_toml_string(whisper.get('server_args', ''))}",
        f"language = {_toml_string(whisper.get('language', 'zh-tw'))}",
        f"beam = {_toml_number(whisper.get('beam', 5), 5)}",
        f"temperature = {_toml_number(whisper.get('temperature', 0), 0)}",
        "",
        "[webui.yt-dlp]",
        f"cookies = {_toml_string(ytdlp.get('cookies', ''))}",
        f"cookies_from_browser = {_toml_string(ytdlp.get('cookies_from_browser', ''))}",
        "",
        "[webui.obsidian]",
        f"vault_name = {_toml_string(obsidian.get('vault_name', ''))}",
        f"default_folder = {_toml_string(obsidian.get('default_folder', ''))}",
        "",
        "[webui.auth]",
        f"enabled = {'true' if auth.get('enabled') else 'false'}",
        f"username = {_toml_string(auth.get('username', 'airtype'))}",
        f"password = {_toml_string(auth.get('password', ''))}",
        "",
        "[[webui.llm-server]]",
        f'name = {_toml_string(llm.get("name", "default"))}',
        f"provider = {_toml_string(llm.get('provider', 'llama.cpp'))}",
        f"endpoint = {_toml_string(llm.get('endpoint', 'http://127.0.0.1:8080'))}",
        f"api_key = {_toml_string(llm.get('api_key', ''))}",
        f"models = {_toml_string_array(llm.get('models', []))}",
        f"selected-model = {_toml_string(llm.get('selected_model', llm.get('model', '')))}",
        f"contextLength = {_toml_number(llm.get('contextLength', 8192), 8192)}",
        f"temperature = {_toml_number(llm.get('temperature', 0.4), 0.4)}",
        f"disable_thinking = {'true' if llm.get('disable_thinking') else 'false'}",
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
    return None


def split_whisper_model_settings(whisper_settings: Dict[str, Any]) -> Tuple[str, str]:
    model_dir = whisper_settings.get("model_dir")
    model_filename = whisper_settings.get("model_filename")
    if model_dir or model_filename:
        return str(model_dir or ""), str(model_filename or "")
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
