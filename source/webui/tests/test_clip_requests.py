"""Clip request JSON files survive a refresh until the user saves them."""

from datetime import datetime
import tempfile
import unittest
from pathlib import Path

from app import clip_requests
from app.clip_requests import infer_step


class ClipRequestStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        clip_requests.configure(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_same_second_uses_a_suffix(self) -> None:
        moment = datetime(2026, 10, 17, 10, 50, 12).astimezone()
        first = clip_requests.create(kind="voice", source="https://example.com/a", now=moment)
        second = clip_requests.create(kind="article", source="https://example.com/b", now=moment)
        self.assertEqual(first["id"], "20261017-105012")
        self.assertEqual(second["id"], "20261017-105012-2")
        self.assertTrue((Path(self.temporary.name) / "requests" / "20261017-105012.json").is_file())

    def test_failed_and_completed_stay_until_saved(self) -> None:
        failed = clip_requests.create(kind="post", source="https://example.com/fail")
        done = clip_requests.create(kind="voice", source="notes.m4a")
        clip_requests.update(failed["id"], status="failed", error="下載失敗", published=True)
        clip_requests.update(done["id"], status="completed", note="hello", published=True)
        pending = {item["id"] for item in clip_requests.list_pending()}
        self.assertIn(failed["id"], pending)
        self.assertIn(done["id"], pending)
        clip_requests.mark_saved(done["id"])
        pending = {item["id"] for item in clip_requests.list_pending()}
        self.assertNotIn(done["id"], pending)
        self.assertIn(failed["id"], pending)

    def test_restart_marks_unfinished_requests_failed(self) -> None:
        queued = clip_requests.create(kind="article", source="https://example.com/page")
        clip_requests.configure(self.temporary.name)
        stored = clip_requests.get(queued["id"])
        self.assertIsNotNone(stored)
        assert stored is not None
        self.assertEqual(stored["status"], "failed")
        self.assertIn("restarted", stored["error"])

    def test_step_follows_the_message_and_delete_removes_the_file(self) -> None:
        self.assertEqual(infer_step("voice", "running", "Transcribing segment 3"), 1)
        self.assertEqual(infer_step("article", "running", "AI polish"), 1)
        self.assertEqual(infer_step("article", "running", "AI 潤稿"), 1)
        self.assertEqual(infer_step("post", "running", "AI tags"), 4)
        self.assertEqual(infer_step("post", "running", "AI 標籤"), 4)
        self.assertEqual(infer_step("voice", "completed", "Completed"), 100)
        created = clip_requests.create(kind="voice", source="https://example.com/a")
        clip_requests.update(created["id"], status="running", message="Transcribing segment 1")
        stored = clip_requests.get(created["id"])
        assert stored is not None
        self.assertEqual(stored["step"], 1)
        self.assertTrue(clip_requests.delete(created["id"]))
        self.assertIsNone(clip_requests.get(created["id"]))
        self.assertNotIn(created["id"], {item["id"] for item in clip_requests.list_pending()})


if __name__ == "__main__":
    unittest.main()
