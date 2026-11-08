"""Named AI routes and per-step route bindings.

A route is a named way to reach a text model:

* ``openai-compat`` routes are the ``webui.llm-server`` entries (local
  oMLX, llama.cpp, Ollama, any OpenAI-compatible server).
* ``grok-cli`` and ``grok-api`` routes live in ``webui.ai-route``.

``webui.ai-steps`` binds each AI step (correct / polish / title / tags) to a
route name. An empty or unknown name means the default local server
(``default-llm-server-name``).

Configs written before routes existed only have ``webui.grok-cli``; they are
read as one ``Grok CLI`` route with the old ``steps`` list as bindings.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, Optional

import re

from . import grok_cli
from .cli_routes import CLI_ROUTE_TYPES
from .config_schema import read_config

AI_STEPS = ("correct", "polish", "title", "tags")
LOCAL_ROUTE_TYPE = "openai-compat"
# OpenAI-compatible chat APIs: endpoint is the API base, /chat/completions is appended.
API_ROUTE_DEFAULTS: Dict[str, Dict[str, Any]] = {
    "grok-api": {"endpoint": "https://api.x.ai", "model": "grok-4"},
    "chatgpt": {"endpoint": "https://api.openai.com/v1", "model": "gpt-4.1-mini"},
    "gemini": {"endpoint": "https://generativelanguage.googleapis.com/v1beta/openai", "model": "gemini-2.5-flash"},
}
API_ROUTE_TYPES = tuple(API_ROUTE_DEFAULTS)
CLI_ROUTE_DEFAULTS: Dict[str, Dict[str, Any]] = {
    "chatgpt-codex": {"bin": "codex", "reasoning_effort": "low"},
    "claude-code": {"bin": "claude", "reasoning_effort": "low"},
}
CLOUD_ROUTE_TYPES = ("grok-cli", *API_ROUTE_TYPES, *CLI_ROUTE_TYPES)
ROUTE_TYPES = (LOCAL_ROUTE_TYPE, *CLOUD_ROUTE_TYPES)
LEGACY_GROK_ROUTE_NAME = "Grok CLI"
DEFAULT_GROK_API_ROUTE: Dict[str, Any] = {
    "endpoint": "https://api.x.ai",
    "api_key": "",
    "model": "grok-4",
    "typo_concurrency": 4,
}


def is_cloud_route(route: Optional[Dict[str, Any]]) -> bool:
    return bool(route) and str(route.get("type") or "") in CLOUD_ROUTE_TYPES


def _clamp_int(value: Any, default: int, minimum: int, maximum: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        number = default
    return max(minimum, min(number, maximum))


def normalize_cloud_route(raw: Any) -> Optional[Dict[str, Any]]:
    """Return a clean grok-cli / grok-api route, or None when it is unusable."""
    if not isinstance(raw, dict):
        return None
    name = str(raw.get("name") or "").strip()
    route_type = str(raw.get("type") or "").strip()
    if not name or route_type not in CLOUD_ROUTE_TYPES:
        return None
    if route_type == "grok-cli":
        settings = grok_cli.normalize_grok_cli_settings(raw)
        return {
            "name": name,
            "type": route_type,
            "bin": settings["bin"],
            "model": settings["model"],
            "reasoning_effort": settings["reasoning_effort"],
            "timeout_seconds": settings["timeout_seconds"],
            "correct_timeout_seconds": settings["correct_timeout_seconds"],
            "typo_concurrency": settings["typo_concurrency"],
        }
    if route_type in CLI_ROUTE_TYPES:
        defaults = CLI_ROUTE_DEFAULTS[route_type]
        return {
            "name": name,
            "type": route_type,
            "bin": str(raw.get("bin") or defaults["bin"]).strip(),
            "model": str(raw.get("model") or "").strip(),
            "reasoning_effort": str(raw.get("reasoning_effort", defaults["reasoning_effort"]) or "").strip(),
            "timeout_seconds": _clamp_int(raw.get("timeout_seconds"), 180, 10, 900),
            "correct_timeout_seconds": _clamp_int(raw.get("correct_timeout_seconds"), 180, 10, 900),
            "typo_concurrency": _clamp_int(raw.get("typo_concurrency"), 4, 1, 8),
        }
    defaults = API_ROUTE_DEFAULTS[route_type]
    return {
        "name": name,
        "type": route_type,
        "endpoint": str(raw.get("endpoint") or defaults["endpoint"]).strip().rstrip("/"),
        "api_key": str(raw.get("api_key") or raw.get("api-key") or ""),
        "model": str(raw.get("model") or defaults["model"]).strip(),
        "typo_concurrency": _clamp_int(raw.get("typo_concurrency"), 4, 1, 8),
    }


def openai_api_url(endpoint: str, suffix: str) -> str:
    """API base + suffix; a base without a version segment (https://api.x.ai) gets /v1."""
    base = str(endpoint or "").strip().rstrip("/")
    if not re.search(r"/v\d+[a-z0-9]*(/openai)?$", base):
        base += "/v1"
    return base + suffix


def normalize_steps(raw: Any) -> Dict[str, str]:
    raw = raw if isinstance(raw, dict) else {}
    return {step: str(raw.get(step) or "").strip() for step in AI_STEPS}


def read_ai_config(config_path: str | Path) -> Dict[str, Any]:
    """Return {"routes": [cloud routes], "steps": {step: name}, "migrated": bool}."""
    webui = read_config(config_path).get("webui", {})
    webui = webui if isinstance(webui, dict) else {}
    raw_routes = webui.get("ai-route")
    if isinstance(raw_routes, dict):
        raw_routes = [raw_routes]
    raw_steps = webui.get("ai-steps")
    if isinstance(raw_routes, list) or isinstance(raw_steps, dict):
        routes: list[Dict[str, Any]] = []
        seen: set[str] = set()
        for raw in raw_routes if isinstance(raw_routes, list) else []:
            route = normalize_cloud_route(raw)
            if route and route["name"] not in seen:
                seen.add(route["name"])
                routes.append(route)
        return {"routes": routes, "steps": normalize_steps(raw_steps), "migrated": False}

    legacy = grok_cli.read_grok_cli_settings(config_path)
    route = normalize_cloud_route({**legacy, "name": LEGACY_GROK_ROUTE_NAME, "type": "grok-cli"})
    default_local = _default_local_name(webui)
    steps = {
        step: (LEGACY_GROK_ROUTE_NAME if grok_cli.handles_step(legacy, step) else default_local)
        for step in AI_STEPS
    }
    return {"routes": [route] if route else [], "steps": steps, "migrated": True}


def _default_local_name(webui: Dict[str, Any]) -> str:
    name = str(webui.get("default-llm-server-name") or "").strip()
    if name:
        return name
    servers = webui.get("llm-server")
    if isinstance(servers, dict):
        servers = [servers]
    for server in servers if isinstance(servers, list) else []:
        if isinstance(server, dict) and str(server.get("name") or "").strip():
            return str(server["name"]).strip()
    return ""


def merge_cloud_routes(incoming: Any, current: list[Dict[str, Any]]) -> list[Dict[str, Any]]:
    """Normalize routes from the Settings form; a blank API key keeps the saved one."""
    saved_keys = {
        route["name"]: route.get("api_key", "")
        for route in current
        if route.get("type") in API_ROUTE_TYPES
    }
    routes: list[Dict[str, Any]] = []
    seen: set[str] = set()
    for raw in incoming if isinstance(incoming, list) else []:
        route = normalize_cloud_route(raw)
        if not route or route["name"] in seen:
            continue
        if route["type"] in API_ROUTE_TYPES and not route["api_key"]:
            route["api_key"] = saved_keys.get(route["name"], "")
        seen.add(route["name"])
        routes.append(route)
    return routes


