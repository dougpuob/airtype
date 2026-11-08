"""Obsidian export manifests for the Local App handoff."""

from datetime import datetime
import tempfile
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from app import clip_requests
from app import obsidian_exports


class ObsidianExportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        clip_requests.configure(self.temporary.name)
        obsidian_exports.configure(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _ready_note(self, source: str = "https://example.com/a", note: str = "# Hello\n") -> dict:
        created = clip_requests.create(kind="article", source=source, now=datetime(2026, 11, 8, 12, 0, 0).astimezone())
        clip_requests.update(
            created["id"],
            status="completed",
            note=note,
            note_title="2026-11-08 Hello",
            title="Hello",
            published=True,
        )
        return clip_requests.get(created["id"]) or {}

    def test_create_export_includes_ready_notes_and_complete_url(self) -> None:
        record = self._ready_note()
        result = obsidian_exports.create(base_url="http://127.0.0.1:8003", vault_folder="Inbox")
        self.assertEqual(result["note_count"], 1)
        self.assertEqual(result["note_ids"], [record["id"]])
        self.assertTrue(result["open_url"].startswith("airtype://obsidian-import?url="))

        token = parse_qs(urlparse(result["download_url"]).query)["token"][0]
        manifest = obsidian_exports.get_manifest(result["export_id"], token)
        self.assertEqual(manifest["kind"], "airtype.obsidian_import")
        self.assertEqual(manifest["vault_folder"], "Inbox")
        self.assertEqual(len(manifest["notes"]), 1)
        self.assertEqual(manifest["notes"][0]["id"], record["id"])
        self.assertEqual(manifest["notes"][0]["markdown"], "# Hello\n")
        self.assertIn("/complete?", manifest["complete"]["url"])
        self.assertTrue((Path(self.temporary.name) / "obsidian-exports" / f"{result['export_id']}.json").is_file())

    def test_create_with_ids_filters_and_rejects_empty(self) -> None:
        first = self._ready_note("https://example.com/1")
        second = self._ready_note("https://example.com/2")
        # Force unique ids when same second stamp collides.
        self.assertNotEqual(first["id"], second["id"])
        result = obsidian_exports.create(base_url="http://host", ids=[first["id"]])
        self.assertEqual(result["note_ids"], [first["id"]])
        with self.assertRaises(ValueError):
            obsidian_exports.create(base_url="http://host", ids=["missing-id"])

    def test_complete_marks_only_saved_ids_from_export(self) -> None:
        first = self._ready_note("https://example.com/1", note="# One\n")
        second = self._ready_note("https://example.com/2", note="# Two\n")
        result = obsidian_exports.create(base_url="http://127.0.0.1:8003")
        token = parse_qs(urlparse(result["download_url"]).query)["token"][0]
        done = obsidian_exports.complete(
            result["export_id"],
            token,
            saved_ids=[first["id"], "not-in-export"],
            failed_ids=[second["id"]],
        )
        self.assertEqual(done["saved_ids"], [first["id"]])
        self.assertEqual(done["failed_ids"], [second["id"]])
        self.assertEqual((clip_requests.get(first["id"]) or {}).get("obsidian_save"), "complete")
        self.assertEqual((clip_requests.get(second["id"]) or {}).get("obsidian_save"), "pending")
        pending = {item["id"] for item in clip_requests.list_pending()}
        self.assertNotIn(first["id"], pending)
        self.assertIn(second["id"], pending)

    def test_bad_token_rejected(self) -> None:
        self._ready_note()
        result = obsidian_exports.create(base_url="http://host")
        with self.assertRaises(KeyError):
            obsidian_exports.get_manifest(result["export_id"], "wrong-token")
        with self.assertRaises(KeyError):
            obsidian_exports.complete(result["export_id"], "wrong-token", saved_ids=result["note_ids"])


if __name__ == "__main__":
    unittest.main()
