"""Run text-only LLM steps through the Grok Build CLI (subscription login).

Only text prompts go to Grok. Audio and video never leave the box; Whisper
still does transcription. Callers fall back to the local LLM on any error.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict, Optional

from .config_schema import read_config

DEFAULT_GROK_CLI_SETTINGS: Dict[str, Any] = {
    "enabled": False,
    "bin": "~/.grok/bin/grok",
    "model": "",
    "reasoning_effort": "low",
    "steps": ["correct", "polish", "title", "tags"],
    "timeout_seconds": 180,
    # Typo correction runs many short calls: tighter timeout, a few in parallel.
    "correct_timeout_seconds": 180,
    "typo_concurrency": 4,
}
ERROR_DETAIL_CHARS = 500
GROK_CLI_STEPS = ("polish", "title", "tags", "correct")


def read_grok_cli_settings(config_path: str | Path) -> Dict[str, Any]:
    """Read [webui.grok-cli]. The WebUI settings writer leaves this section alone."""
    webui = read_config(config_path).get("webui", {})
    section = webui.get("grok-cli") if isinstance(webui, dict) else None
    section = section if isinstance(section, dict) else {}
    settings = {**DEFAULT_GROK_CLI_SETTINGS, **section}
    settings["enabled"] = bool(settings.get("enabled"))
    settings["bin"] = str(settings.get("bin") or DEFAULT_GROK_CLI_SETTINGS["bin"])
    settings["model"] = str(settings.get("model") or "").strip()
    settings["reasoning_effort"] = str(settings.get("reasoning_effort") or "").strip()
    steps = settings.get("steps")
    settings["steps"] = [
        str(step).strip() for step in steps if str(step).strip() in GROK_CLI_STEPS
    ] if isinstance(steps, list) else list(DEFAULT_GROK_CLI_SETTINGS["steps"])
    try:
        settings["timeout_seconds"] = max(10, min(int(settings.get("timeout_seconds") or 180), 900))
    except (TypeError, ValueError):
        settings["timeout_seconds"] = DEFAULT_GROK_CLI_SETTINGS["timeout_seconds"]
    try:
        settings["correct_timeout_seconds"] = max(
            10, min(int(settings.get("correct_timeout_seconds") or 180), 900)
        )
    except (TypeError, ValueError):
        settings["correct_timeout_seconds"] = DEFAULT_GROK_CLI_SETTINGS["correct_timeout_seconds"]
    try:
        settings["typo_concurrency"] = max(1, min(int(settings.get("typo_concurrency") or 4), 8))
    except (TypeError, ValueError):
        settings["typo_concurrency"] = DEFAULT_GROK_CLI_SETTINGS["typo_concurrency"]
    return settings


def step_timeout(settings: Dict[str, Any], step: str) -> int:
    if str(step or "").strip() == "correct":
        return int(settings.get("correct_timeout_seconds") or DEFAULT_GROK_CLI_SETTINGS["correct_timeout_seconds"])
    return int(settings.get("timeout_seconds") or DEFAULT_GROK_CLI_SETTINGS["timeout_seconds"])


class GrokTimeout(RuntimeError):
    """The CLI did not answer within the timeout."""


def _error_detail(completed: Any) -> str:
    """Keep the tail of stderr and stdout so failures are diagnosable."""
    parts = []
    for name in ("stderr", "stdout"):
        text = str(getattr(completed, name, "") or "").strip()
        if text:
            parts.append(f"{name}: {' '.join(text[-ERROR_DETAIL_CHARS:].split())}")
    return " | ".join(parts)


def handles_step(settings: Dict[str, Any], step: str) -> bool:
    return bool(settings.get("enabled")) and str(step or "").strip() in settings.get("steps", [])


def build_command(settings: Dict[str, Any], prompt_path: str, system: str) -> list[str]:
    command = [
        os.path.expanduser(settings["bin"]),
        "--no-auto-update",
        "--prompt-file", prompt_path,
        "--verbatim",
        "--output-format", "json",
        "--max-turns", "1",
        "--tools", "none",
        "--permission-mode", "dontAsk",
        "--disable-web-search",
        "--no-subagents",
    ]
    if system.strip():
        command += ["--system-prompt-override", system]
    if settings.get("model"):
        command += ["--model", settings["model"]]
    if settings.get("reasoning_effort"):
        command += ["--reasoning-effort", settings["reasoning_effort"]]
    return command


def run_grok_cli(
    system: str,
    prompt: str,
    settings: Dict[str, Any],
    run: Any = subprocess.run,
    timeout: Optional[int] = None,
) -> tuple[str, Dict[str, Any]]:
    """Return (text, payload). Raises RuntimeError when Grok cannot answer."""
    timeout = int(timeout or settings["timeout_seconds"])
    with tempfile.TemporaryDirectory(prefix="airtype-grok-") as work_dir:
        prompt_path = os.path.join(work_dir, "prompt.txt")
        with open(prompt_path, "w", encoding="utf-8") as prompt_file:
            prompt_file.write(prompt)
        try:
            completed = run(
                build_command(settings, prompt_path, system or ""),
                cwd=work_dir,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as error:
            raise GrokTimeout(f"grok timed out after {timeout}s") from error
        except OSError as error:
            raise RuntimeError(f"grok could not start: {error}") from error
    if completed.returncode != 0:
        raise RuntimeError(f"grok exited {completed.returncode}: {_error_detail(completed)}")
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"grok returned non-JSON output: {_error_detail(completed)}") from error
    if not isinstance(payload, dict):
        raise RuntimeError("grok returned an unexpected payload")
    stop_reason = str(payload.get("stopReason") or "")
    if stop_reason and stop_reason != "end_turn":
        raise RuntimeError(f"grok stopped early: {stop_reason}")
    text = str(payload.get("text") or "").strip()
    if not text:
        raise RuntimeError("grok returned empty text")
    return text, payload


def usage_payload(payload: Dict[str, Any]) -> Dict[str, Any]:
    """Map Grok usage to the OpenAI-style keys llm-usage.jsonl expects."""
    usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
    return {
        "usage": {
            "prompt_tokens": usage.get("input_tokens"),
            "completion_tokens": usage.get("output_tokens"),
            "total_tokens": usage.get("total_tokens"),
        }
    }


def payload_model(payload: Dict[str, Any], fallback: str = "") -> str:
    models = payload.get("modelUsage")
    if isinstance(models, dict) and models:
        return str(next(iter(models)))
    return fallback or "grok-cli"
