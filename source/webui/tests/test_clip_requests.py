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

    def test_notes_are_stored_and_land_in_the_obsidian_draft(self) -> None:
        from app.clip_pipeline import build_draft

        created = clip_requests.create(
            kind="article",
            source="https://example.com/page",
            notes="  why I clipped this\n",
        )
        self.assertEqual(created["notes"], "  why I clipped this")
        clip_requests.update(created["id"], status="running", message="AI polish")
        stored = clip_requests.get(created["id"])
        assert stored is not None
        self.assertEqual(stored["notes"], "  why I clipped this")
        draft = build_draft(
            kind="article",
            title="Hello",
            content="body",
            polished="polished",
            ai_tags="",
            sources=["https://example.com/page"],
            guid="guid",
            share_url="",
            notes=stored["notes"],
        )
        self.assertIn('notes: "  why I clipped this"\n', draft["note"])
        self.assertIn("# Notes\n\n  why I clipped this\n", draft["note"])
        self.assertIn("# SQNA\n\n- **🙋🏻‍♂️  ?**\n\t-  ↪ \n\t-  ↪ \n\t-  ↪ \n", draft["note"])
        self.assertLess(draft["note"].index("# Notes"), draft["note"].index("# SQNA"))
        self.assertLess(draft["note"].index("# SQNA"), draft["note"].index("# AI Tags"))
        self.assertNotIn("# Original External Content", draft["note"])
        self.assertEqual(draft["notes"], "  why I clipped this")

    def test_origin_defaults_to_manual_and_can_be_watching(self) -> None:
        manual = clip_requests.create(kind="article", source="https://example.com/page")
        watching = clip_requests.create(kind="post", source="https://example.com/post", origin="watching")
        telegram = clip_requests.create(kind="article", source="https://example.com/tg", origin="telegram")
        unknown = clip_requests.create(kind="voice", source="clip.m4a", origin="elsewhere")
        self.assertEqual(manual["origin"], "manual")
        self.assertEqual(watching["origin"], "watching")
        self.assertEqual(telegram["origin"], "telegram")
        self.assertEqual(unknown["origin"], "manual")
        self.assertEqual(clip_requests.get(watching["id"])["origin"], "watching")

    def test_idempotency_key_reuses_one_request_across_restart(self) -> None:
        key = "telegram:15:0:abcdefabcdefabcd"
        first, created = clip_requests.upsert_idempotent(
            kind="article",
            source="https://example.com/once",
            origin="telegram",
            idempotency_key=key,
        )
        self.assertTrue(created)
        second, created_again = clip_requests.upsert_idempotent(
            kind="article",
            source="https://example.com/once",
            origin="telegram",
            idempotency_key=key,
        )
        self.assertFalse(created_again)
        self.assertEqual(second["id"], first["id"])
        self.assertEqual(clip_requests.find_by_idempotency_key(key)["id"], first["id"])
        clip_requests.configure(self.temporary.name)
        stored = clip_requests.get(first["id"])
        self.assertIsNotNone(stored)
        assert stored is not None
        self.assertTrue(clip_requests.was_interrupted(stored))
        interrupted = clip_requests.interrupted_with_key_prefix("telegram:")
        self.assertEqual([item["id"] for item in interrupted], [first["id"]])
        with self.assertRaises(ValueError):
            clip_requests.upsert_idempotent(
                kind="article",
                source="https://example.com/once",
                idempotency_key="has spaces",
            )

    def test_notes_are_capped_and_empty_by_default(self) -> None:
        empty = clip_requests.create(kind="post", source="https://example.com/post")
        self.assertEqual(empty["notes"], "")
        long_note = "x" * 2500
        created = clip_requests.create(kind="voice", source="clip.m4a", notes=long_note)
        self.assertEqual(len(created["notes"]), 2000)

    def test_pending_index_tracks_unsaved_and_drops_saved(self) -> None:
        index_path = Path(self.temporary.name) / "clip-requests-pending.json"
        first = clip_requests.create(kind="voice", source="a.m4a")
        second = clip_requests.create(kind="article", source="https://example.com/b")
        self.assertTrue(index_path.is_file())
        ids = set(__import__("json").loads(index_path.read_text(encoding="utf-8"))["ids"])
        self.assertEqual(ids, {first["id"], second["id"]})
        clip_requests.update(first["id"], status="completed", note="hello", published=True)
        clip_requests.mark_saved(first["id"])
        ids = __import__("json").loads(index_path.read_text(encoding="utf-8"))["ids"]
        self.assertNotIn(first["id"], ids)
        self.assertIn(second["id"], ids)
        pending = {item["id"] for item in clip_requests.list_pending()}
        self.assertNotIn(first["id"], pending)
        self.assertIn(second["id"], pending)

    def test_rebuild_pending_index_rescans_request_files(self) -> None:
        index_path = Path(self.temporary.name) / "clip-requests-pending.json"
        kept = clip_requests.create(kind="voice", source="keep.m4a")
        saved = clip_requests.create(kind="voice", source="saved.m4a")
        clip_requests.update(saved["id"], status="completed", note="x", published=True)
        clip_requests.mark_saved(saved["id"])
        # Corrupt the index so a rebuild is needed.
        index_path.write_text('{"ids": ["missing-id", "' + saved["id"] + '"]}\n', encoding="utf-8")
        rebuilt = clip_requests.rebuild_pending_index()
        self.assertEqual(set(rebuilt), {kept["id"]})
        self.assertEqual(set(__import__("json").loads(index_path.read_text(encoding="utf-8"))["ids"]), {kept["id"]})

    def test_list_pending_is_cached_until_something_changes(self) -> None:
        import gzip
        import json
        from unittest import mock

        first = clip_requests.create(kind="voice", source="a.m4a")
        second = clip_requests.create(kind="article", source="https://example.com/b")
        clip_requests.update(first["id"], status="completed", note="hello", published=True)
        etag1, body1 = clip_requests.pending_response_body()
        self.assertEqual({item["id"] for item in json.loads(body1)["requests"]}, {first["id"], second["id"]})

        # Warm: no request file or index file is read again.
        with mock.patch.object(Path, "read_text", side_effect=AssertionError("file read on warm path")):
            self.assertEqual(len(clip_requests.list_pending()), 2)
            etag2, body2 = clip_requests.pending_response_body()
            _, packed = clip_requests.pending_response_body(compress=True)
        self.assertEqual(etag1, etag2)
        self.assertIs(body1, body2)
        self.assertEqual(gzip.decompress(packed), body1)

        # Callers get copies; mutating them does not poison the cache.
        clip_requests.list_pending()[0]["title"] = "mutated"
        self.assertNotIn("mutated", [item["title"] for item in clip_requests.list_pending()])

        # mark_saved drops it and changes the ETag.
        clip_requests.mark_saved(first["id"])
        etag3, body3 = clip_requests.pending_response_body()
        self.assertNotEqual(etag3, etag1)
        self.assertEqual([item["id"] for item in json.loads(body3)["requests"]], [second["id"]])

        # Status updates show up.
        clip_requests.update(second["id"], status="running", message="AI polish")
        self.assertEqual(clip_requests.list_pending()[0]["status"], "running")

        # Delete drops it.
        self.assertTrue(clip_requests.delete(second["id"]))
        self.assertEqual(clip_requests.list_pending(), [])

    def test_list_response_is_slim_and_get_returns_the_full_record(self) -> None:
        import json

        done = clip_requests.create(kind="article", source="https://example.com/a")
        clip_requests.update(
            done["id"],
            status="completed",
            note="# full note",
            content="raw body",
            polished_content="polished body",
            external_content="external body",
            title="Title",
        )
        running = clip_requests.create(kind="voice", source="b.m4a")
        _, body = clip_requests.pending_response_body()
        listed = {item["id"]: item for item in json.loads(body)["requests"]}
        for item in listed.values():
            for field in clip_requests.HEAVY_FIELDS:
                self.assertNotIn(field, item)
            self.assertTrue(item["summary"])
        self.assertTrue(listed[done["id"]]["has_note"])
        self.assertTrue(listed[done["id"]]["has_content"])
        self.assertEqual(listed[done["id"]]["title"], "Title")
        self.assertEqual(listed[done["id"]]["status"], "completed")
        self.assertFalse(listed[running["id"]]["has_note"])
        self.assertEqual({item["id"] for item in clip_requests.list_pending_slim()}, set(listed))

        full = clip_requests.get(done["id"])
        assert full is not None
        self.assertEqual(full["note"], "# full note")
        self.assertEqual(full["content"], "raw body")
        self.assertEqual(full["polished_content"], "polished body")
        self.assertEqual(full["external_content"], "external body")
        self.assertNotIn("summary", full)

    def test_cache_notices_files_edited_outside_the_module(self) -> None:
        import json
        import os

        created = clip_requests.create(kind="voice", source="a.m4a")
        self.assertEqual(clip_requests.list_pending()[0]["title"], "")
        path = Path(self.temporary.name) / "requests" / f"{created['id']}.json"
        record = json.loads(path.read_text(encoding="utf-8"))
        record["title"] = "edited by hand"
        path.write_text(json.dumps(record), encoding="utf-8")
        info = os.stat(path)
        os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns + 1_000_000))
        self.assertEqual(clip_requests.list_pending()[0]["title"], "edited by hand")

        # A new id appended to the index by hand is picked up too.
        index_path = Path(self.temporary.name) / "clip-requests-pending.json"
        other = dict(record, id="20990101-000000", title="other", created_at="2099-01-01T00:00:00+08:00")
        (Path(self.temporary.name) / "requests" / "20990101-000000.json").write_text(json.dumps(other), encoding="utf-8")
        index_path.write_text(json.dumps({"ids": ["20990101-000000", created["id"]]}), encoding="utf-8")
        info = os.stat(index_path)
        os.utime(index_path, ns=(info.st_atime_ns, info.st_mtime_ns + 1_000_000))
        self.assertEqual([item["id"] for item in clip_requests.list_pending()], ["20990101-000000", created["id"]])

    def test_rebuild_pending_index_resets_the_cache(self) -> None:
        kept = clip_requests.create(kind="voice", source="keep.m4a")
        etag_before, _ = clip_requests.pending_response_body()
        extra = clip_requests.create(kind="voice", source="extra.m4a")
        clip_requests.rebuild_pending_index()
        etag_after, body = clip_requests.pending_response_body()
        self.assertNotEqual(etag_before, etag_after)
        self.assertEqual({item["id"] for item in __import__("json").loads(body)["requests"]}, {kept["id"], extra["id"]})


if __name__ == "__main__":
    unittest.main()
