"""Tests for the Grok CLI text provider."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from app import grok_cli


def _settings(**overrides):
    return {**grok_cli.DEFAULT_GROK_CLI_SETTINGS, "enabled": True, **overrides}


def _fake_run(stdout="", returncode=0, stderr="", seen=None):
    def run(command, **kwargs):
        if seen is not None:
            seen["command"] = command
            seen["kwargs"] = kwargs
            prompt_path = command[command.index("--prompt-file") + 1]
            seen["prompt"] = Path(prompt_path).read_text(encoding="utf-8")
            seen["cwd_files"] = sorted(os.listdir(kwargs["cwd"]))
        return SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr)

    return run


class ReadSettingsTests(unittest.TestCase):
    def _read(self, webui: dict):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text(json.dumps({"webui": webui}, indent=2) + "\n", encoding="utf-8")
            return grok_cli.read_grok_cli_settings(path)

    def test_correct_timeout_and_concurrency_settings(self) -> None:
        settings = self._read({"grok-cli": {"enabled": True, "timeout_seconds": 300}})
        self.assertEqual(settings["typo_concurrency"], 4)
        self.assertEqual(grok_cli.step_timeout(settings, "correct"), 180)
        self.assertEqual(grok_cli.step_timeout(settings, "polish"), 300)
        settings = self._read(
            {"grok-cli": {"enabled": True, "correct_timeout_seconds": 90, "typo_concurrency": 99}}
        )
        self.assertEqual(grok_cli.step_timeout(settings, "correct"), 90)
        self.assertEqual(settings["typo_concurrency"], 8)
        settings = self._read({"grok-cli": {"typo_concurrency": "x"}})
        self.assertEqual(settings["typo_concurrency"], 4)

    def test_disabled_without_section(self) -> None:
        settings = self._read({"ime": {"correction_enabled": False}})
        self.assertFalse(settings["enabled"])
        self.assertFalse(grok_cli.handles_step(settings, "polish"))

    def test_reads_section_and_filters_steps(self) -> None:
        settings = self._read(
            {"grok-cli": {"enabled": True, "steps": ["polish", "tags", "bogus"], "timeout_seconds": 5}}
        )
        self.assertTrue(grok_cli.handles_step(settings, "polish"))
        self.assertTrue(grok_cli.handles_step(settings, "tags"))
        self.assertFalse(grok_cli.handles_step(settings, "title"))
        self.assertFalse(grok_cli.handles_step(settings, ""))
        self.assertEqual(settings["steps"], ["polish", "tags"])
        self.assertEqual(settings["timeout_seconds"], 10)


class RunGrokCliTests(unittest.TestCase):
    def test_returns_text_and_uses_safe_flags(self) -> None:
        seen = {}
        stdout = json.dumps({"text": "  潤稿結果  ", "stopReason": "end_turn", "usage": {"input_tokens": 3}})
        text, payload = grok_cli.run_grok_cli("系統", "長文字" * 50, _settings(model="grok-4.6"), run=_fake_run(stdout, seen=seen))
        self.assertEqual(text, "潤稿結果")
        self.assertEqual(payload["usage"]["input_tokens"], 3)
        command = seen["command"]
        self.assertNotIn("--always-approve", command)
        self.assertIn("--disable-web-search", command)
        self.assertEqual(command[command.index("--tools") + 1], "none")
        self.assertEqual(command[command.index("--system-prompt-override") + 1], "系統")
        self.assertEqual(command[command.index("--model") + 1], "grok-4.6")
        self.assertEqual(command[command.index("--reasoning-effort") + 1], "low")
        self.assertEqual(seen["prompt"], "長文字" * 50)
        self.assertEqual(seen["cwd_files"], ["prompt.txt"])
        self.assertEqual(seen["kwargs"]["stdin"], subprocess.DEVNULL)

    def test_failures_raise(self) -> None:
        cases = [
            _fake_run("", returncode=1, stderr="Not signed in"),
            _fake_run("not json"),
            _fake_run(json.dumps({"text": "", "stopReason": "end_turn"})),
            _fake_run(json.dumps({"text": "半句", "stopReason": "max_turns"})),
        ]
        for run in cases:
            with self.assertRaises(RuntimeError):
                grok_cli.run_grok_cli("", "x", _settings(), run=run)

    def test_timeout_raises(self) -> None:
        def run(command, **kwargs):
            raise subprocess.TimeoutExpired(command, kwargs["timeout"])

        with self.assertRaises(RuntimeError):
            grok_cli.run_grok_cli("", "x", _settings(), run=run)

    def test_timeout_is_grok_timeout_and_uses_override(self) -> None:
        seen = {}

        def run(command, **kwargs):
            seen["timeout"] = kwargs["timeout"]
            raise subprocess.TimeoutExpired(command, kwargs["timeout"])

        with self.assertRaises(grok_cli.GrokTimeout):
            grok_cli.run_grok_cli("", "x", _settings(timeout_seconds=300), run=run, timeout=180)
        self.assertEqual(seen["timeout"], 180)

    def test_nonzero_exit_keeps_more_than_last_line(self) -> None:
        stderr = "first problem\nsecond detail\nlast line"
        with self.assertRaises(RuntimeError) as caught:
            grok_cli.run_grok_cli("", "x", _settings(), run=_fake_run("partial out", returncode=2, stderr=stderr))
        message = str(caught.exception)
        self.assertIn("first problem", message)
        self.assertIn("last line", message)
        self.assertIn("partial out", message)
        long_err = "e" * 2000
        with self.assertRaises(RuntimeError) as caught:
            grok_cli.run_grok_cli("", "x", _settings(), run=_fake_run("", returncode=1, stderr=long_err))
        self.assertLess(len(str(caught.exception)), 600)

    def test_missing_binary_raises(self) -> None:
        with self.assertRaises(RuntimeError):
            grok_cli.run_grok_cli("", "x", _settings(bin="/nonexistent/grok"))

    def test_usage_mapping(self) -> None:
        payload = {
            "usage": {"input_tokens": 10, "output_tokens": 2, "total_tokens": 12},
            "modelUsage": {"grok-4.6-build": {}},
        }
        self.assertEqual(
            grok_cli.usage_payload(payload)["usage"],
            {"prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 12},
        )
        self.assertEqual(grok_cli.payload_model(payload), "grok-4.6-build")
        self.assertEqual(grok_cli.payload_model({}), "grok-cli")


if __name__ == "__main__":
    unittest.main()
