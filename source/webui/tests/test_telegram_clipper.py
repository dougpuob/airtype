"""Telegram private-chat intake. No network and no bot token on disk."""

from __future__ import annotations

import json
import os
import stat
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from app import telegram_clipper as tg
from app.config_schema import remove_webui_sections
from app import web_article


TOKEN = "999999:ABCDEFGHIJKLMNOPQRSTUVWXYZ12"
PAGE = "https://example.com/story"


class FakeTransport:
    def __init__(self, updates=None, webhook_url="", updates_error=None):
        self.updates = list(updates or [])
        self.webhook_url = webhook_url
        self.updates_error = updates_error
        self.calls = []

    def call(self, method, params, timeout):
        self.calls.append((method, dict(params)))
        if method == "deleteWebhook":
            raise AssertionError("deleteWebhook must not be called")
        if method == "getWebhookInfo":
            return {"ok": True, "result": {"url": self.webhook_url, "pending_update_count": 0}}
        if method == "getUpdates":
            if self.updates_error is not None:
                raise self.updates_error
            offset = int(params.get("offset") or 0)
            batch = [item for item in self.updates if int(item["update_id"]) >= offset]
            return {"ok": True, "result": batch}
        if method == "sendMessage":
            return {"ok": True, "result": {"message_id": 1}}
        raise AssertionError(method)


def _settings(**overrides):
    values = dict(
        enabled=True,
        token=TOKEN,
        token_file="",
        token_error="",
        allowed_user_id=42,
        allowed_chat_id=99,
        replies_enabled=False,
    )
    values.update(overrides)
    return tg.Settings(**values)


def _entity(text, url):
    del url
    return [{"type": "url", "offset": 0, "length": len(text.encode("utf-16-le")) // 2}]


def _update(update_id, text, *, user_id=42, chat_id=99, chat_type="private", entities=None, caption=None, caption_entities=None):
    message = {
        "message_id": update_id,
        "from": {"id": user_id, "username": "douglas", "first_name": "Douglas", "language_code": "en"},
        "chat": {"id": chat_id, "type": chat_type},
    }
    if caption is not None:
        message["caption"] = caption
        message["caption_entities"] = caption_entities or []
    else:
        message["text"] = text
        message["entities"] = entities if entities is not None else _entity(text, text)
    return {"update_id": update_id, "message": message}


class PollerFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.logs: list[str] = []
        self.submitted: list[dict] = []

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def poller(self, transport, settings=None, submit=None):
        return tg.Poller(
            settings_loader=lambda: settings or _settings(),
            state_path=Path(self.temporary.name) / "state.json",
            pairing_path=Path(self.temporary.name) / "pairing-candidates.json",
            submit=submit or self._submit,
            log=self.logs.append,
            transport_factory=lambda token: transport,
            poll_timeout=0,
        )

    def _submit(self, url, **kwargs):
        self.submitted.append({"url": url, **kwargs})
        return {"id": f"clip-{len(self.submitted)}"}

    def log_text(self) -> str:
        return "\n".join(self.logs)


class TargetFilterTests(unittest.TestCase):
    def test_matches_clipper_host_policy_and_keeps_tailscale(self) -> None:
        blocked = [
            "https://localhost/x",
            "http://127.0.0.1:8000/x",
            "http://192.168.1.10/x",
            "http://10.0.0.5/x",
            "http://172.16.0.1/x",
            "http://169.254.169.254/latest/meta-data/",
            "http://[::1]/x",
            "http://0.0.0.0/",
            "http://printer.local/x",
        ]
        for url in blocked:
            with self.subTest(url=url):
                self.assertTrue(web_article.blocked_host_reason(url), url)
                self.assertEqual(tg.blocked_target_reason(url), "blocked_host")
        allowed = [
            "https://blog.example.com/post",
            "https://airtype.tail84298.ts.net/health",
            "http://100.64.1.5/clip",
            "http://100.100.100.100/",
            "http://[fd7a:115c:a1e0::1]/",
            "http://192.0.2.1/docs",
        ]
        for url in allowed:
            with self.subTest(url=url):
                self.assertEqual(web_article.blocked_host_reason(url), "")
                self.assertEqual(tg.blocked_target_reason(url), "")

    def test_obfuscated_literals_metadata_and_credentials(self) -> None:
        for url in (
            "http://2130706433/",
            "http://0x7f000001/",
            "http://0177.0.0.1/",
            "http://127.1/",
            "http://[::ffff:127.0.0.1]/",
            "http://[::ffff:169.254.169.254]/latest/meta-data",
            "http://[fe80::1]/",
            "http://100.100.169.254/latest/meta-data/",
        ):
            self.assertEqual(tg.blocked_target_reason(url), "blocked_host", url)
        self.assertEqual(tg.blocked_target_reason("http://metadata.google.internal/computeMetadata/v1/"), "metadata_host")
        self.assertEqual(tg.blocked_target_reason("http://user:secret@example.com/a"), "url_credentials")
        self.assertEqual(tg.blocked_target_reason("file:///etc/passwd"), "bad_scheme")
        self.assertEqual(tg.blocked_target_reason("http://example.com@" + "127.0.0.1/"), "url_credentials")


class SettingsTests(unittest.TestCase):
    def test_fail_closed_until_both_ids_and_enabled_are_set(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "config.toml"
            path.write_text("[webui]\n", encoding="utf-8")
            unset = tg.load_settings(path, env={})
            self.assertFalse(unset.enabled)
            self.assertFalse(unset.allowlist_ready)
            self.assertNotIn(TOKEN, repr(unset))
            path.write_text(
                "\n".join(
                    [
                        "[webui.telegram]",
                        "enabled = true",
                        "allowed_user_id = 42",
                        "allowed_chat_id = 0",
                        "replies_enabled = false",
                        "token_file = \"\"",
                    ]
                ),
                encoding="utf-8",
            )
            partial = tg.load_settings(path, env={})
            self.assertTrue(partial.enabled)
            self.assertIsNone(partial.allowed_chat_id)
            self.assertFalse(partial.allowlist_ready)
            ready = tg.load_settings(
                path,
                env={
                    "AIRTYPE_TELEGRAM_BOT_TOKEN": TOKEN,
                    "AIRTYPE_TELEGRAM_ALLOWED_CHAT_ID": "99",
                },
            )
            self.assertTrue(ready.allowlist_ready)
            self.assertEqual(ready.allowed_user_id, 42)
            self.assertEqual(ready.allowed_chat_id, 99)
            self.assertNotIn(TOKEN, repr(ready))
            self.assertFalse(ready.replies_enabled)

    def test_token_file_is_not_echoed_and_loose_mode_is_warned(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            token_path = Path(temporary) / "token"
            token_path.write_text(TOKEN + "\n", encoding="utf-8")
            os.chmod(token_path, 0o644)
            config = Path(temporary) / "config.toml"
            config.write_text(
                f'[webui.telegram]\nenabled = true\ntoken_file = "{token_path}"\nallowed_user_id = 1\nallowed_chat_id = 1\n',
                encoding="utf-8",
            )
            loaded = tg.load_settings(config, env={})
            self.assertEqual(loaded.token, TOKEN)
            self.assertIn("chmod 600", tg.token_file_warning(str(token_path)))
            self.assertNotIn(TOKEN, tg.token_file_warning(str(token_path)))
            self.assertEqual(stat.S_IMODE(token_path.stat().st_mode), 0o644)


class IntakeTests(PollerFixture):
    def test_authorized_entities_are_queued_once(self) -> None:
        page = "https://example.com/from-entity"
        caption_url = "https://cdn.example.com/clip"
        text = "👍 " + page
        offset = len("👍 ".encode("utf-16-le")) // 2
        updates = [
            _update(
                10,
                text,
                entities=[
                    {"type": "url", "offset": offset, "length": len(page.encode("utf-16-le")) // 2},
                    {"type": "text_link", "offset": 0, "length": 1, "url": "https://example.com/linked"},
                ],
            ),
            _update(
                11,
                "",
                caption="photo",
                caption_entities=[{"type": "text_link", "offset": 0, "length": 5, "url": caption_url}],
            ),
        ]
        # Naive Python slicing would drop the scheme because the emoji is one
        # code point and two UTF-16 units. The entity above uses the UTF-16 offset.
        self.assertNotEqual(text[offset : offset + len(page)], page)
        transport = FakeTransport(updates)
        poller = self.poller(transport)
        self.assertEqual(poller.run_once(_settings()), 2)
        self.assertEqual(
            [item["url"] for item in self.submitted],
            [page, "https://example.com/linked", caption_url],
        )
        self.assertEqual(poller.run_once(_settings()), 0)
        self.assertEqual(len(self.submitted), 3)
        self.assertNotIn("sendMessage", [call[0] for call in transport.calls])
        self.assertNotIn(page, self.log_text())
        state = (Path(self.temporary.name) / "state.json").read_text(encoding="utf-8")
        self.assertNotIn(page, state)
        self.assertNotIn(TOKEN, state)
        self.assertNotIn(TOKEN, self.log_text())

    def test_unauthorized_and_unset_allowlist_do_not_enqueue(self) -> None:
        updates = [
            _update(1, PAGE, user_id=7, chat_id=7),
            _update(2, PAGE, user_id=42, chat_id=100),
            _update(3, PAGE, chat_type="group"),
            _update(4, PAGE, user_id=42, chat_id=99),
        ]
        updates[2]["message"].pop("from")
        transport = FakeTransport(updates[:3])
        self.poller(transport).run_once(_settings())
        self.assertEqual(self.submitted, [])
        self.assertIn("reason=allowlist", self.log_text())
        self.assertIn("reason=not_private", self.log_text())
        closed = FakeTransport([updates[3]])
        self.logs.clear()
        self.poller(closed, settings=_settings(allowed_user_id=None, allowed_chat_id=None)).run_once(
            _settings(allowed_user_id=None, allowed_chat_id=None)
        )
        self.assertEqual(self.submitted, [])
        self.assertIn("reason=allowlist_unset", self.log_text())

    def test_start_records_candidate_without_trust_or_fetch(self) -> None:
        secret = "https://user:secret-token@example.com/private"
        updates = [
            _update(5, "/start " + secret, entities=[{"type": "url", "offset": 7, "length": len(secret)}]),
            _update(6, "/whoami", entities=[]),
            _update(7, "/start", user_id=8, chat_id=8, entities=[]),
            _update(8, "/start", chat_type="supergroup", entities=[]),
        ]
        settings = _settings(allowed_user_id=None, allowed_chat_id=None)
        transport = FakeTransport(updates)
        poller = self.poller(transport, settings=settings)
        poller.run_once(settings)
        self.assertEqual(self.submitted, [])
        self.assertFalse(settings.allowlist_ready)
        pairing = json.loads((Path(self.temporary.name) / "pairing-candidates.json").read_text(encoding="utf-8"))
        self.assertEqual([(item["user_id"], item["chat_id"], item["command"]) for item in pairing], [(8, 8, "/start"), (42, 99, "/whoami")])
        blob = json.dumps(pairing)
        self.assertNotIn("secret-token", blob)
        self.assertNotIn("http", blob)
        self.assertNotIn("secret-token", self.log_text())
        self.assertIn("user_id=42 chat_id=99", self.log_text())
        mode = stat.S_IMODE((Path(self.temporary.name) / "pairing-candidates.json").stat().st_mode)
        self.assertEqual(mode & 0o077, 0)

    def test_malicious_targets_are_not_submitted(self) -> None:
        urls = [
            "http://127.0.0.1/admin",
            "http://169.254.169.254/latest/meta-data/",
            "http://2130706433/",
            "http://metadata.google.internal/",
            "http://user:secret-token@example.com/a",
            PAGE,
        ]
        text = " ".join(urls)
        entities = [{"type": "text_link", "offset": 0, "length": 1, "url": "file:///etc/passwd"}]
        for url in urls:
            offset = len(text[: text.index(url)].encode("utf-16-le")) // 2
            entities.append({"type": "url", "offset": offset, "length": len(url.encode("utf-16-le")) // 2})
        transport = FakeTransport([_update(20, text, entities=entities)])
        self.poller(transport).run_once(_settings())
        self.assertEqual([item["url"] for item in self.submitted], [PAGE])
        self.assertNotIn("secret-token", self.log_text())
        self.assertNotIn("169.254.169.254", self.log_text())
        self.assertIn("blocked_host", self.log_text())

    def test_url_limit(self) -> None:
        urls = [f"https://example.com/p/{index}" for index in range(6)]
        text = " ".join(urls)
        entities = []
        for url in urls:
            offset = len(text[: text.index(url)].encode("utf-16-le")) // 2
            entities.append({"type": "url", "offset": offset, "length": len(url.encode("utf-16-le")) // 2})
        self.poller(FakeTransport([_update(21, text, entities=entities)])).run_once(_settings())
        self.assertEqual(len(self.submitted), tg.MAX_URLS_PER_MESSAGE)
        self.assertIn("limit=1", self.log_text())

    def test_crash_before_offset_commit_does_not_enqueue_twice(self) -> None:
        transport = FakeTransport([_update(30, PAGE)])
        poller = self.poller(transport)

        def crash(offset):
            raise RuntimeError("crash before offset")

        poller._state.commit_offset = crash
        with self.assertRaises(RuntimeError):
            poller.run_once(_settings())
        self.assertEqual(len(self.submitted), 1)
        state_text = (Path(self.temporary.name) / "state.json").read_text(encoding="utf-8")
        self.assertNotIn(PAGE, state_text)
        self.assertIn("clip-1", state_text)
        restarted = self.poller(FakeTransport([_update(30, PAGE)]))
        restarted.run_once(_settings())
        self.assertEqual(len(self.submitted), 1)
        self.assertEqual(restarted._state.next_offset, 31)

    def test_enqueue_failure_is_retried_and_submit_dedupes_a_lost_ack(self) -> None:
        state = {"fail": True}

        def submit(url, **kwargs):
            self.submitted.append(kwargs["idempotency_key"])
            if state["fail"]:
                state["fail"] = False
                raise RuntimeError("queue unavailable")
            return {"id": "20261107-120000"}

        transport = FakeTransport([_update(40, PAGE)])
        poller = self.poller(transport, submit=submit)
        with self.assertRaises(RuntimeError):
            poller.run_once(_settings())
        self.assertEqual(poller._state.next_offset, 0)
        poller.run_once(_settings())
        self.assertEqual(self.submitted[0], self.submitted[1])
        self.assertEqual(poller._state.next_offset, 41)

        created = {}

        def deduped(url, **kwargs):
            key = kwargs["idempotency_key"]
            if key in created:
                return created[key]
            created[key] = {"id": "20261107-120001"}
            self.submitted.append("created")
            raise RuntimeError("crash after enqueue")

        lost = self.poller(FakeTransport([_update(41, "https://example.com/other")]), submit=deduped)
        with self.assertRaises(RuntimeError):
            lost.run_once(_settings())
        lost.run_once(_settings())
        self.assertEqual(self.submitted.count("created"), 1)
        self.assertEqual(lost._state.next_offset, 42)

    def test_webhook_conflict_does_not_poll_or_delete(self) -> None:
        transport = FakeTransport(webhook_url="https://hook.example/telegram?secret=hook-secret")
        poller = self.poller(transport)
        with self.assertRaises(tg.TelegramApiError) as caught:
            poller.run_once(_settings())
        self.assertEqual(caught.exception.status, 409)
        self.assertEqual([call[0] for call in transport.calls], ["getWebhookInfo"])
        self.assertNotIn("hook-secret", str(caught.exception))
        conflict = FakeTransport(updates_error=tg.TelegramApiError(409, "Conflict: can't use getUpdates"))
        with self.assertRaises(tg.TelegramApiError):
            self.poller(conflict).run_once(_settings())
        self.assertNotIn("deleteWebhook", [call[0] for call in conflict.calls])

    def test_replies_are_off_unless_enabled_and_do_not_echo_urls(self) -> None:
        quiet = FakeTransport([_update(50, PAGE)])
        self.poller(quiet).run_once(_settings())
        self.assertNotIn("sendMessage", [call[0] for call in quiet.calls])
        chatty = FakeTransport([_update(51, PAGE)])
        self.poller(chatty, settings=_settings(replies_enabled=True)).run_once(_settings(replies_enabled=True))
        replies = [call for call in chatty.calls if call[0] == "sendMessage"]
        self.assertEqual(len(replies), 1)
        self.assertEqual(replies[0][1]["chat_id"], 99)
        self.assertNotIn("http", replies[0][1]["text"])
        self.assertIn("Queued 1 clip.", replies[0][1]["text"])

    def test_disabled_and_missing_token_do_not_call_telegram(self) -> None:
        transport = FakeTransport([_update(60, PAGE)])
        self.assertEqual(self.poller(transport, settings=_settings(enabled=False)).run_once(_settings(enabled=False)), 0)
        self.assertEqual(transport.calls, [])
        self.assertEqual(self.poller(transport, settings=_settings(token="")).run_once(_settings(token="")), 0)
        self.assertEqual(transport.calls, [])

    def test_backoff_and_redaction(self) -> None:
        poller = self.poller(FakeTransport())
        self.assertEqual([poller.failure_wait(tg.TelegramApiError(0, "network error")) for _ in range(3)], [1.0, 2.0, 4.0])
        self.assertEqual(poller.failure_wait(tg.TelegramApiError(429, "too many", retry_after=12)), 12.0)
        self.assertEqual(poller.failure_wait(tg.TelegramApiError(401, "unauthorized")), 60.0)
        self.assertEqual(poller.failure_wait(tg.TelegramApiError(409, "conflict")), 30.0)
        leaked = f"https://api.telegram.org/bot{TOKEN}/getUpdates failed for http://user:secret-token@example.com/a?token=abc"
        cleaned = tg.redact(leaked, TOKEN)
        self.assertNotIn(TOKEN, cleaned)
        self.assertNotIn("secret-token", cleaned)
        self.assertNotIn("token=abc", cleaned)

    def test_serve_returns_when_stopped(self) -> None:
        stop = threading.Event()
        stop.set()
        self.poller(FakeTransport([_update(61, PAGE)])).serve(stop)
        self.assertEqual(self.submitted, [])

    def test_single_consumer_lock(self) -> None:
        path = Path(self.temporary.name) / ".poller.lock"
        first = tg.acquire_poll_lock(path)
        self.assertIsNotNone(first)
        self.assertIsNone(tg.acquire_poll_lock(path))
        import fcntl

        fcntl.flock(first, fcntl.LOCK_UN)
        first.close()
        second = tg.acquire_poll_lock(path)
        self.assertIsNotNone(second)
        second.close()

    def test_settings_save_keeps_the_telegram_table(self) -> None:
        text = "[webui.telegram]\nenabled = false\ntoken_file = \"/etc/airtype/telegram-bot-token\"\nallowed_user_id = 0\nallowed_chat_id = 0\n\n[webui.auth]\nenabled = true\n"
        kept = remove_webui_sections(text)
        self.assertIn("[webui.telegram]", kept)
        self.assertIn("/etc/airtype/telegram-bot-token", kept)
        self.assertNotIn("[webui.auth]", kept)


class ClipEnqueueTests(unittest.TestCase):
    def test_submit_clip_url_reuses_the_request_and_redrives_only_interruptions(self) -> None:
        os.environ["AIRTYPE_DISABLE_TELEGRAM_CLIPPER"] = "1"
        from app import main as webui

        with tempfile.TemporaryDirectory() as temporary:
            from app import clip_requests

            clip_requests.configure(temporary)
            key = "telegram:70:0:abcdefabcdefabcd"
            with patch.object(webui.clip_executor, "submit", return_value=None) as scheduled:
                first = webui._submit_clip_url(PAGE, origin="telegram", idempotency_key=key)
                second = webui._submit_clip_url(PAGE, origin="telegram", idempotency_key=key)
                self.assertEqual(first["id"], second["id"])
                self.assertEqual(first["origin"], "telegram")
                self.assertEqual(scheduled.call_count, 1)
                clip_requests.update(
                    first["id"],
                    status="failed",
                    progress=100,
                    message="Failed",
                    error=clip_requests.INTERRUPTED_ERROR,
                )
                third = webui._submit_clip_url(PAGE, origin="telegram", idempotency_key=key)
                self.assertEqual(third["id"], first["id"])
                self.assertEqual(third["status"], "queued")
                self.assertEqual(scheduled.call_count, 2)
                clip_requests.update(first["id"], status="failed", error="Page returned 404", message="Failed", progress=100)
                fourth = webui._submit_clip_url(PAGE, origin="telegram", idempotency_key=key)
                self.assertEqual(fourth["id"], first["id"])
                self.assertEqual(scheduled.call_count, 2)

            youtube = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
            voice_key = "telegram:71:0:abcdefabcdefabcd"

            def create_job(*args, **kwargs):
                webui.transcription_jobs["job-voice"] = {"clip_request_id": ""}
                return "job-voice"

            with patch.object(webui, "_settings_transcribe_options", return_value={}), patch.object(
                webui, "_settings_request_info", return_value={}
            ), patch.object(webui, "_create_job", side_effect=create_job), patch.object(
                webui, "_job_dir", return_value=temporary
            ), patch.object(webui, "_update_job_source"), patch.object(
                webui.executor, "submit", return_value=None
            ) as voice_scheduled:
                voice = webui._submit_clip_url(youtube, origin="telegram", idempotency_key=voice_key)
                again = webui._submit_clip_url(youtube, origin="telegram", idempotency_key=voice_key)
                self.assertEqual(voice["kind"], "voice")
                self.assertEqual(again["id"], voice["id"])
                self.assertEqual(voice_scheduled.call_count, 1)


if __name__ == "__main__":
    unittest.main()
