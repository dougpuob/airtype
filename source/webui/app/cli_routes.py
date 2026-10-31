"""Run text-only AI steps through subscription CLIs: OpenAI Codex and Claude Code.

Both mirror the grok-cli route: one non-interactive turn, no tools, prompt in a
temp dir, the CLI's own saved login. Callers handle fallback.

* chatgpt-codex: ``codex exec --ephemeral --sandbox read-only --skip-git-repo-check
  -o <file> -`` (prompt on stdin, final message written to <file>).
* claude-code: ``claude -p --output-format json --max-turns 1 --tools ""
  --system-prompt-file <file> --no-session-persistence`` (prompt on stdin).
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from typing import Any, Callable, Dict, Optional

CLI_ROUTE_TYPES = ("chatgpt-codex", "claude-code")
EXTRA_BIN_DIRS = ("/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.npm-global/bin", "~/.bun/bin", "~/.claude/local")
ERROR_DETAIL_CHARS = 400


class CliTimeout(RuntimeError):
    """The CLI did not answer within the timeout."""


def resolve_bin(binary: str) -> str:
    """Absolute path for a configured binary; bare names are searched on PATH plus common install dirs."""
    binary = os.path.expanduser(str(binary or "").strip())
    if not binary:
        return ""
    if os.sep in binary:
        return binary
    search = os.pathsep.join([os.environ.get("PATH", ""), *[os.path.expanduser(d) for d in EXTRA_BIN_DIRS]])
    return shutil.which(binary, path=search) or ""


def _env(binary: str) -> Dict[str, str]:
    # npm-installed CLIs are `#!/usr/bin/env node` scripts; make sure node is findable.
    env = dict(os.environ)
    extra = [os.path.dirname(binary), *[os.path.expanduser(d) for d in EXTRA_BIN_DIRS]]
    env["PATH"] = os.pathsep.join([*extra, env.get("PATH", "")])
    return env


def _detail(completed: Any) -> str:
    parts = []
    for name in ("stderr", "stdout"):
        text = str(getattr(completed, name, "") or "").strip()
        if text:
            parts.append(f"{name}: {' '.join(text[-ERROR_DETAIL_CHARS:].split())}")
    return " | ".join(parts)


def build_command(route: Dict[str, Any], binary: str, work_dir: str, system: str) -> tuple[list[str], str]:
    """Return (argv, output_path). output_path is empty when the answer is on stdout."""
    route_type = route.get("type")
    model = str(route.get("model") or "").strip()
    effort = str(route.get("reasoning_effort") or "").strip()
    if route_type == "chatgpt-codex":
        output_path = os.path.join(work_dir, "answer.txt")
        command = [
            binary, "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--color", "never",
            "-o", output_path,
        ]
        if model:
            command += ["-m", model]
        if effort:
            command += ["-c", f"model_reasoning_effort={effort}"]
        command.append("-")
        return command, output_path
    if route_type == "claude-code":
        command = [
            binary, "-p",
            "--output-format", "json",
            "--max-turns", "1",
            "--tools", "",
            "--no-session-persistence",
        ]
        if system.strip():
            system_path = os.path.join(work_dir, "system.txt")
            with open(system_path, "w", encoding="utf-8") as system_file:
                system_file.write(system)
            command += ["--system-prompt-file", system_path]
        if model:
            command += ["--model", model]
        if effort:
            command += ["--effort", effort]
        return command, ""
    raise ValueError(f"not a CLI route type: {route_type}")


def _codex_prompt(system: str, prompt: str) -> str:
    # codex exec has no system-prompt flag; keep instructions first and explicit.
    if not system.strip():
        return prompt
    return f"Follow these instructions exactly. Reply with the answer text only.\n\n{system.strip()}\n\n---\n\n{prompt}"


def run_cli_route(
    route: Dict[str, Any],
    system: str,
    prompt: str,
    timeout: int,
    run: Callable[..., Any] = subprocess.run,
) -> tuple[str, Dict[str, Any]]:
    """Return (text, usage_payload). Raises RuntimeError / CliTimeout on failure."""
    binary = resolve_bin(route.get("bin") or "")
    if not binary or not os.path.isfile(binary):
        raise RuntimeError(f"{route.get('type')} binary not found: {route.get('bin') or '(empty)'}")
    route_type = route.get("type")
    stdin_text = _codex_prompt(system or "", prompt) if route_type == "chatgpt-codex" else prompt
    with tempfile.TemporaryDirectory(prefix=f"airtype-{route_type}-") as work_dir:
        command, output_path = build_command(route, binary, work_dir, system or "")
        try:
            completed = run(
                command,
                cwd=work_dir,
                input=stdin_text,
                capture_output=True,
                text=True,
                timeout=timeout,
                env=_env(binary),
            )
        except subprocess.TimeoutExpired as error:
            raise CliTimeout(f"{route_type} timed out after {timeout}s") from error
        except OSError as error:
            raise RuntimeError(f"{route_type} could not start: {error}") from error
        if completed.returncode != 0:
            raise RuntimeError(f"{route_type} exited {completed.returncode}: {_detail(completed)}")
        if route_type == "chatgpt-codex":
            text = ""
            if output_path and os.path.exists(output_path):
                with open(output_path, encoding="utf-8") as answer_file:
                    text = answer_file.read().strip()
            text = text or str(completed.stdout or "").strip()
            if not text:
                raise RuntimeError("codex returned empty text")
            return text, {}
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"claude returned non-JSON output: {_detail(completed)}") from error
    if not isinstance(payload, dict):
        raise RuntimeError("claude returned an unexpected payload")
    if payload.get("is_error") or (payload.get("subtype") and payload.get("subtype") != "success"):
        raise RuntimeError(f"claude failed: {payload.get('subtype')} {str(payload.get('result') or '')[:200]}")
    text = str(payload.get("result") or "").strip()
    if not text:
        raise RuntimeError("claude returned empty text")
    usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
    return text, {
        "usage": {
            "prompt_tokens": usage.get("input_tokens"),
            "completion_tokens": usage.get("output_tokens"),
            "total_tokens": (usage.get("input_tokens") or 0) + (usage.get("output_tokens") or 0) or None,
        }
    }


def probe_cli_route(route: Dict[str, Any], run: Callable[..., Any] = subprocess.run) -> str:
    """Cheap check: binary found, --version works, and the CLI reports a saved login."""
    route_type = route.get("type")
    binary = resolve_bin(route.get("bin") or "")
    if not binary or not os.path.isfile(binary):
        raise ValueError(f"{route_type} binary not found: {route.get('bin') or '(empty)'} (install it or set the full path)")
    if not os.access(binary, os.X_OK):
        raise ValueError(f"binary is not executable: {binary}")
    common = dict(stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15, env=_env(binary))
    version = run([binary, "--version"], **common)
    if version.returncode != 0:
        raise ValueError(f"--version exited {version.returncode}: {_detail(version)}")
    version_text = (str(version.stdout or "").strip().splitlines() or [route_type])[0]
    auth_command = [binary, "login", "status"] if route_type == "chatgpt-codex" else [binary, "auth", "status"]
    auth = run(auth_command, **common)
    if auth.returncode != 0:
        login = "codex login" if route_type == "chatgpt-codex" else "claude auth login"
        raise ValueError(f"{version_text} found but not signed in (run `{login}`)")
    return f"{version_text} · signed in"
