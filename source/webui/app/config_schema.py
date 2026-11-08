from __future__ import annotations

import json
import os
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
    "web_to_markdown": {
        "api_key": "",
        "timeout_seconds": 60,
        "download_max_mb": 20,
    },
    "immich": {
        "server_url": "",
        "api_key": "",
        "create_album": False,
    },
    "obsidian": {
        "vault_name": "",
        "default_folder": "",
    },
    "capture_post": {
        "ai_title_enabled": True,
        "title_system_prompt": "你是擅長提煉文章重點的繁體中文標題編輯。請根據使用者提供的文章產生一個約 30 個字的標題；不要使用冒號、不要提供多個選項、不要加入引號或解釋，只輸出標題。",
        "thinking_steps": ["title"],
        "tags_thinking_level": "mid",
    },
    "ime": {
        "correction_enabled": False,
    },
    "auth": {
        "enabled": False,
        "username": "airtype",
        "password": "",
        "session_days": 14,
    },
}
LLM_THINKING_STEPS = ("polish", "title", "tags")
# Shared thinking levels (關 / 低 / 中 / 高). Each connection method maps a level to
# its own request params; methods without a thinking knob simply ignore it.
THINKING_LEVELS = ("off", "low", "mid", "high")
DEFAULT_TAGS_THINKING_LEVEL = "mid"
# Local OpenAI-compatible servers (oMLX): thinking token cap per level.
THINKING_LEVEL_BUDGETS = {"low": 256, "mid": 512, "high": 1024}
DEFAULT_WEBUI_DATA_DIR = "~/.airtype/data"
DEFAULT_CONFIG_SCHEMA_PATH = Path(__file__).resolve().parents[3] / "config.schema.json"

WEBUI_SECTION_ALIASES = {
    "whisper": ("whisper-server",),
    "llm": ("llm-server",),
    "ytdlp": ("yt-dlp", "ytdlp"),
    "web_to_markdown": ("web-to-markdown",),
    "immich": ("immich",),
    "obsidian": ("obsidian",),
    "capture_post": ("capture-post", "capture_post"),
    "ime": ("ime",),
    "auth": ("auth",),
}


def read_config(path: str | Path) -> Dict[str, Any]:
    config_path = Path(path)
    if not config_path.exists():
        return {}

    try:
        loaded = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return {}

    return loaded if isinstance(loaded, dict) else {}


def ensure_config_exists(
    path: str | Path,
    schema_path: str | Path = DEFAULT_CONFIG_SCHEMA_PATH,
    generator_name: str = "webui",
) -> Path:
    """Ensure ~/.airtype/config.json exists; create schema defaults when missing."""
    del path, generator_name  # always use the shared JSON home path
    home = Path("~/.airtype").expanduser()
    json_path = (home / "config.json").resolve()

    if json_path.exists():
        return json_path

    schema_file = Path(schema_path)
    schema = json.loads(schema_file.read_text(encoding="utf-8"))
    defaults = _schema_defaults_object(schema)
    # Ensure whisper model_dir default points at models/whisper.
    webui = defaults.setdefault("webui", {})
    if isinstance(webui, dict):
        whisper = webui.get("whisper-server")
        if isinstance(whisper, dict):
            whisper.setdefault("model_dir", "~/.airtype/models/whisper")
        elif whisper is None:
            webui["whisper-server"] = {"model_dir": "~/.airtype/models/whisper"}
    json_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(defaults, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return json_path


def _schema_defaults_object(schema: Dict[str, Any]) -> Dict[str, Any]:
    """Best-effort nested defaults from JSON Schema properties (for first-run config.json)."""
    props = schema.get("properties") if isinstance(schema, dict) else None
    if not isinstance(props, dict):
        return {}

    def walk(node: Dict[str, Any]) -> Any:
        if not isinstance(node, dict):
            return {}
        if "default" in node:
            return node["default"]
        if node.get("type") == "array":
            items = node.get("items")
            if isinstance(items, dict) and "default" in items:
                return [items["default"]]
            if isinstance(items, dict) and isinstance(items.get("properties"), dict):
                return [walk(items)]
            return []
        nested = node.get("properties")
        if isinstance(nested, dict):
            return {key: walk(value) for key, value in nested.items()}
        return {}

    return {key: walk(value) for key, value in props.items()}


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


def normalize_thinking_steps(value: Any, *, use_default: bool = False) -> list[str]:
    if use_default and not isinstance(value, list):
        return list(DEFAULT_APP_SETTINGS["capture_post"]["thinking_steps"])
    steps: list[str] = []
    for item in value if isinstance(value, list) else []:
        step = str(item or "").strip()
        if step in LLM_THINKING_STEPS and step not in steps:
            steps.append(step)
    return steps


def thinking_enabled_for_step(step: str, thinking_steps: Any) -> bool:
    return str(step or "").strip() in normalize_thinking_steps(thinking_steps)


def normalize_thinking_level(value: Any, default: str = DEFAULT_TAGS_THINKING_LEVEL) -> str:
    level = str(value or "").strip().lower()
    aliases = {"關": "off", "none": "off", "false": "off", "低": "low", "中": "mid", "medium": "mid", "高": "high"}
    level = aliases.get(level, level)
    return level if level in THINKING_LEVELS else default


def thinking_budget_for_level(level: Any) -> Optional[int]:
    """Token cap for a thinking level; None for ``off``."""
    return THINKING_LEVEL_BUDGETS.get(normalize_thinking_level(level))


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

    web_to_markdown_input = _dict_value(normalized.get("web_to_markdown"))
    web_to_markdown = {**DEFAULT_APP_SETTINGS["web_to_markdown"], **web_to_markdown_input}
    if "api_key" not in web_to_markdown_input and "api-key" in web_to_markdown_input:
        web_to_markdown["api_key"] = web_to_markdown_input["api-key"]
    web_to_markdown["api_key"] = str(web_to_markdown.get("api_key") or "")
    web_to_markdown["timeout_seconds"] = _int_in_range(
        web_to_markdown.get("timeout_seconds"), 60, minimum=5, maximum=300
    )
    web_to_markdown["download_max_mb"] = _int_in_range(
        web_to_markdown.get("download_max_mb"), 20, minimum=1, maximum=200
    )

    immich_input = _dict_value(normalized.get("immich"))
    immich = {**DEFAULT_APP_SETTINGS["immich"], **immich_input}
    if "server_url" not in immich_input and "server-url" in immich_input:
        immich["server_url"] = immich_input["server-url"]
    if "api_key" not in immich_input and "api-key" in immich_input:
        immich["api_key"] = immich_input["api-key"]
    immich["server_url"] = str(immich.get("server_url") or "").strip().rstrip("/")
    immich["api_key"] = str(immich.get("api_key") or "")
    immich["create_album"] = bool(immich.get("create_album"))

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

    capture_post_input = _dict_value(normalized.get("capture_post"))
    capture_post = {
        **DEFAULT_APP_SETTINGS["capture_post"],
        **capture_post_input,
    }
    if "ai_title_enabled" not in capture_post_input and "ai-title-enabled" in capture_post_input:
        capture_post["ai_title_enabled"] = capture_post_input["ai-title-enabled"]
    if "title_system_prompt" not in capture_post_input and "title-system-prompt" in capture_post_input:
        capture_post["title_system_prompt"] = capture_post_input["title-system-prompt"]
    if "thinking_steps" not in capture_post_input and "thinking-steps" in capture_post_input:
        capture_post["thinking_steps"] = capture_post_input["thinking-steps"]
    capture_post["ai_title_enabled"] = bool(capture_post.get("ai_title_enabled"))
    capture_post["title_system_prompt"] = str(capture_post.get("title_system_prompt") or "")
    has_thinking_steps = "thinking_steps" in capture_post_input or "thinking-steps" in capture_post_input
    capture_post["thinking_steps"] = normalize_thinking_steps(
        capture_post.get("thinking_steps"),
        use_default=not has_thinking_steps,
    )
    if "tags_thinking_level" not in capture_post_input and "tags-thinking-level" in capture_post_input:
        capture_post["tags_thinking_level"] = capture_post_input["tags-thinking-level"]
    capture_post["tags_thinking_level"] = normalize_thinking_level(capture_post.get("tags_thinking_level"))
    # Tags thinking is driven by tags_thinking_level; "tags" in thinking_steps is ignored.

    ime_input = _dict_value(normalized.get("ime"))
    ime = {
        **DEFAULT_APP_SETTINGS["ime"],
        **ime_input,
    }
    ime["correction_enabled"] = bool(ime.get("correction_enabled"))

    auth = {**DEFAULT_APP_SETTINGS["auth"], **_dict_value(normalized.get("auth"))}
    auth["enabled"] = bool(auth.get("enabled"))
    auth["username"] = str(auth.get("username") or "airtype")
    auth["password"] = str(auth.get("password") or "")
    auth["session_days"] = _int_in_range(auth.get("session_days"), 14, minimum=1, maximum=90)

    return {
        "whisper": whisper,
        "llm": llm,
        "ytdlp": ytdlp,
        "web_to_markdown": web_to_markdown,
        "immich": immich,
        "obsidian": obsidian,
        "capture_post": capture_post,
        "ime": ime,
        "auth": auth,
    }


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
