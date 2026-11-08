import json
import os
import tempfile
import unittest
from unittest import mock

from app import ai_routes
from app import main as webui

LEGACY_CONFIG = {
    "webui": {
        "llm-server": [
            {
                "name": "omlx",
                "provider": "openai",
                "endpoint": "http://127.0.0.1:8000",
                "api_key": "local-secret",
                "models": ["qwen"],
                "selected-model": "qwen",
            }
        ],
        "default-llm-server-name": "omlx",
        "grok-cli": {
            "enabled": True,
            "bin": "~/.grok/bin/grok",
            "reasoning_effort": "low",
            "steps": ["correct", "polish"],
            "timeout_seconds": 300,
            "typo_concurrency": 3,
        },
    }
}


class AiRoutesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "config.json")
        with open(self.path, "w", encoding="utf-8") as config_file:
            json.dump(LEGACY_CONFIG, config_file, indent=2)
            config_file.write("\n")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_legacy_grok_cli_becomes_route_and_bindings(self) -> None:
        config = ai_routes.read_ai_config(self.path)
        self.assertTrue(config["migrated"])
        self.assertEqual([route["name"] for route in config["routes"]], ["Grok CLI"])
        self.assertEqual(config["routes"][0]["timeout_seconds"], 300)
        self.assertEqual(
            config["steps"], {"correct": "Grok CLI", "polish": "Grok CLI", "title": "omlx", "tags": "omlx"}
        )

    def test_normalize_filters_routes(self) -> None:
        routes = [
            {"name": "CLI", "type": "grok-cli", "timeout_seconds": 200},
            {"name": "xAI", "type": "grok-api", "api_key": "k", "model": "grok-4"},
            {"name": "", "type": "grok-api"},
            {"name": "bad", "type": "nope"},
        ]
        normalized = [route for raw in routes if (route := ai_routes.normalize_cloud_route(raw))]
        self.assertEqual([route["name"] for route in normalized], ["CLI", "xAI"])
        steps = ai_routes.normalize_steps({"title": "xAI"})
        self.assertEqual(steps["title"], "xAI")
        self.assertEqual(steps["correct"], "")

    def test_blank_api_key_keeps_saved_key(self) -> None:
        current = [{"name": "xAI", "type": "grok-api", "api_key": "saved"}]
        merged = ai_routes.merge_cloud_routes([{"name": "xAI", "type": "grok-api", "api_key": ""}], current)
        self.assertEqual(merged[0]["api_key"], "saved")

    def test_settings_save_keeps_routes_and_migrates(self) -> None:
        with mock.patch.object(webui, "CONFIG_PATH", self.path):
            settings = webui._read_app_settings()
            self.assertEqual(
                [(route["name"], route["type"]) for route in settings["ai_routes"]],
                [("omlx", "openai-compat"), ("Grok CLI", "grok-cli")],
            )
            # A save without route fields (older client) must keep the Grok route.
            webui._write_app_settings(webui._settings_request_to_nested({"llm": settings["llm"]}))
            config = ai_routes.read_ai_config(self.path)
            self.assertFalse(config["migrated"])
            self.assertEqual(config["routes"][0]["name"], "Grok CLI")
            self.assertEqual(config["steps"]["polish"], "Grok CLI")
            with open(self.path, encoding="utf-8") as config_file:
                raw = json.load(config_file)["webui"]
            self.assertIn("grok-cli", raw)  # legacy table left in place
            self.assertEqual(raw["llm-server"][0]["api_key"], "local-secret")

            # Settings form: add an API route, a second local route, rebind steps.
            incoming = {
                "llm": settings["llm"],
                "default_llm_server_name": "omlx",
                "ai_routes": settings["ai_routes"]
                + [
                    {"name": "xAI", "type": "grok-api", "api_key": "xai-secret", "model": "grok-4"},
                    {"name": "other", "type": "openai-compat", "provider": "ollama",
                     "endpoint": "http://127.0.0.1:11434", "models": ["llama"], "selected_model": "llama"},
                ],
                "ai_steps": {"correct": "Grok CLI", "polish": "xAI", "title": "other", "tags": ""},
            }
            saved = webui._write_app_settings(webui._settings_request_to_nested(incoming))
            self.assertEqual(saved["default_llm_server_name"], "omlx")
            self.assertEqual(webui._resolve_step_route("polish")["type"], "grok-api")
            self.assertEqual(webui._resolve_step_route("title")["endpoint"], "http://127.0.0.1:11434")
            self.assertEqual(webui._resolve_step_route("tags"), {"type": "openai-compat", "name": ""})
            self.assertEqual(webui._resolve_step_route(""), {"type": "openai-compat", "name": ""})
            self.assertEqual(webui._typo_concurrency(), 3)

            # Saving again with a blank key keeps the stored xAI key.
            again = dict(incoming)
            again["ai_routes"] = [
                {**route, "api_key": ""} if route.get("name") == "xAI" else route for route in incoming["ai_routes"]
            ]
            webui._write_app_settings(webui._settings_request_to_nested(again))
            self.assertEqual(webui._resolve_step_route("polish")["api_key"], "xai-secret")

    def test_local_route_overrides_request_and_api_route_falls_back(self) -> None:
        request = webui.LocalChatRequest(
            provider="openai", endpoint="http://default", model="m", system="s", prompt="p", step="title"
        )
        local_route = {"type": "openai-compat", "name": "other", "provider": "ollama",
                       "endpoint": "http://other", "selected_model": "llama"}
        with mock.patch.object(webui, "_resolve_step_route", return_value=local_route), mock.patch.object(
            webui, "_local_chat_completion", return_value=("ok", {})
        ) as local, mock.patch.object(webui, "_record_llm_usage"):
            self.assertEqual(webui._local_chat_response(request), "ok")
        sent = local.call_args.args[0]
        self.assertEqual((sent.provider, sent.endpoint, sent.model), ("ollama", "http://other", "llama"))

        api_route = {"type": "grok-api", "name": "xAI", "endpoint": "https://api.x.ai", "api_key": "k", "model": "g"}
        with mock.patch.object(webui, "_resolve_step_route", return_value=api_route), mock.patch.object(
            webui, "_http_json", side_effect=ValueError("HTTP 401")
        ) as cloud, mock.patch.object(
            webui, "_local_chat_completion", return_value=("local", {})
        ) as local, mock.patch.object(webui, "_record_llm_usage"), mock.patch.object(webui, "append_service_log"):
            self.assertEqual(webui._local_chat_response(request), "local")
            with self.assertRaises(webui.GrokCorrectFailed):
                webui._local_chat_response(request.model_copy(update={"step": "correct"}))
        self.assertEqual(cloud.call_args_list[0].args[1], "https://api.x.ai/v1/chat/completions")
        self.assertEqual(local.call_count, 1)

        gemini = ai_routes.normalize_cloud_route({"name": "G", "type": "gemini", "api_key": "k"})
        reply = {"choices": [{"message": {"content": "gem"}}]}
        with mock.patch.object(webui, "_resolve_step_route", return_value=gemini), mock.patch.object(
            webui, "_http_json", return_value=reply
        ) as cloud, mock.patch.object(webui, "_record_llm_usage"):
            self.assertEqual(webui._local_chat_response(request), "gem")
        self.assertEqual(
            cloud.call_args.args[1], "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        )
        self.assertEqual(cloud.call_args.args[2]["model"], "gemini-2.5-flash")

        chatgpt = ai_routes.normalize_cloud_route({"name": "C", "type": "chatgpt", "api_key": "k"})
        with mock.patch.object(webui, "_resolve_step_route", return_value=chatgpt), mock.patch.object(
            webui, "_http_json", return_value=reply
        ) as cloud, mock.patch.object(webui, "_record_llm_usage"):
            webui._local_chat_response(request)
        self.assertEqual(cloud.call_args.args[1], "https://api.openai.com/v1/chat/completions")
        self.assertNotIn("temperature", cloud.call_args.args[2])

    def test_cli_routes_run_and_fall_back(self) -> None:
        from app import cli_routes

        request = webui.LocalChatRequest(
            provider="openai", endpoint="http://default", model="m", system="SYS", prompt="PROMPT", step="tags"
        )
        codex = ai_routes.normalize_cloud_route({"name": "Codex", "type": "chatgpt-codex", "bin": "/bin/echo"})
        seen = {}

        def fake_codex(command, **kwargs):
            seen["command"], seen["input"] = command, kwargs["input"]
            with open(command[command.index("-o") + 1], "w", encoding="utf-8") as answer:
                answer.write("#標籤 #Tag\n")
            return mock.Mock(returncode=0, stdout="", stderr="")

        text, _ = cli_routes.run_cli_route(codex, "SYS", "PROMPT", 30, run=fake_codex)
        self.assertEqual(text, "#標籤 #Tag")
        self.assertEqual(seen["command"][:2], ["/bin/echo", "exec"])
        self.assertIn("--ephemeral", seen["command"])
        self.assertIn("read-only", seen["command"])
        self.assertIn("model_reasoning_effort=low", seen["command"])
        self.assertTrue(seen["input"].endswith("PROMPT") and "SYS" in seen["input"])

        claude = ai_routes.normalize_cloud_route(
            {"name": "Claude", "type": "claude-code", "bin": "/bin/echo", "model": "sonnet"}
        )

        def fake_claude(command, **kwargs):
            seen["command"] = command
            seen["system"] = open(command[command.index("--system-prompt-file") + 1], encoding="utf-8").read()
            return mock.Mock(
                returncode=0,
                stdout='{"type":"result","subtype":"success","is_error":false,"result":"hi","usage":{"input_tokens":3,"output_tokens":1}}',
                stderr="",
            )

        text, usage = cli_routes.run_cli_route(claude, "SYS", "PROMPT", 30, run=fake_claude)
        self.assertEqual((text, usage["usage"]["total_tokens"], seen["system"]), ("hi", 4, "SYS"))
        self.assertEqual(seen["command"][seen["command"].index("--tools") + 1], "")
        self.assertIn("sonnet", seen["command"])

        with mock.patch.object(webui, "_resolve_step_route", return_value=claude), mock.patch.object(
            cli_routes, "run_cli_route", side_effect=RuntimeError("not signed in")
        ), mock.patch.object(webui, "_local_chat_completion", return_value=("local", {})), mock.patch.object(
            webui, "_record_llm_usage"
        ), mock.patch.object(webui, "append_service_log"):
            self.assertEqual(webui._local_chat_response(request), "local")
            with self.assertRaises(webui.GrokCorrectFailed):
                webui._local_chat_response(request.model_copy(update={"step": "correct"}))

    def test_cli_probe_reports_login(self) -> None:
        from app import cli_routes

        route = {"type": "claude-code", "bin": "/bin/echo"}
        ok = lambda command, **kwargs: mock.Mock(returncode=0, stdout="2.1.300 (Claude Code)\n", stderr="")
        self.assertEqual(cli_routes.probe_cli_route(route, run=ok), "2.1.300 (Claude Code) · signed in")
        logged_out = lambda command, **kwargs: mock.Mock(
            returncode=1 if "status" in command else 0, stdout="codex-cli 0.50.0", stderr=""
        )
        with self.assertRaisesRegex(ValueError, "codex login"):
            cli_routes.probe_cli_route({"type": "chatgpt-codex", "bin": "/bin/echo"}, run=logged_out)
        with self.assertRaisesRegex(ValueError, "not found"):
            cli_routes.probe_cli_route({"type": "claude-code", "bin": "definitely-not-installed-cli"})

    def test_api_url_helper(self) -> None:
        self.assertEqual(ai_routes.openai_api_url("https://api.x.ai", "/models"), "https://api.x.ai/v1/models")
        self.assertEqual(ai_routes.openai_api_url("https://api.openai.com/v1/", "/models"), "https://api.openai.com/v1/models")
        self.assertEqual(
            ai_routes.openai_api_url("https://generativelanguage.googleapis.com/v1beta/openai", "/models"),
            "https://generativelanguage.googleapis.com/v1beta/openai/models",
        )

    def test_route_connection_checks(self) -> None:
        with self.assertRaisesRegex(ValueError, "not found"):
            webui._test_ai_route({"type": "grok-cli", "bin": "/nonexistent/grok"})
        with mock.patch.object(webui, "CONFIG_PATH", self.path):
            with self.assertRaisesRegex(ValueError, "no API key"):
                webui._test_ai_route({"type": "grok-api", "name": "missing"})
        with mock.patch.object(
            webui, "_http_json_with_timeout", side_effect=ValueError("HTTP 400 from https://api.x.ai/v1/models")
        ):
            with self.assertRaisesRegex(ValueError, "API key rejected"):
                webui._test_ai_route({"type": "grok-api", "name": "x", "api_key": "bad"})
        with mock.patch.object(webui, "_http_json_with_timeout", return_value={"data": [{"id": "grok-4"}]}):
            self.assertEqual(
                webui._test_ai_route({"type": "grok-api", "name": "x", "api_key": "k", "model": "grok-4"}),
                "1 models available",
            )
        with mock.patch.object(webui, "_check_local_llm_health") as health:
            webui._test_ai_route({"type": "openai-compat", "provider": "openai", "endpoint": "http://x"})
        health.assert_called_once_with("openai", "http://x", None)


if __name__ == "__main__":
    unittest.main()
