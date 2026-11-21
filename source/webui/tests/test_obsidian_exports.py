"""Obsidian export manifests for the Local App handoff."""

from datetime import datetime
import json
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

    def test_complete_response_does_not_contain_token(self) -> None:
        record = self._ready_note()
        result = obsidian_exports.create(base_url="http://127.0.0.1:8003")
        token = parse_qs(urlparse(result["download_url"]).query)["token"][0]
        done = obsidian_exports.complete(result["export_id"], token, saved_ids=[record["id"]])
        self.assertNotIn(token, json.dumps(done))
        self.assertTrue(done["ok"])
        self.assertEqual(done["saved_ids"], [record["id"]])
        self.assertEqual(done["rejected"], [])

    def test_duplicate_complete_is_idempotent_and_keeps_new_notes(self) -> None:
        record = self._ready_note("https://example.com/idem")
        result = obsidian_exports.create(base_url="http://127.0.0.1:8003")
        token = parse_qs(urlparse(result["download_url"]).query)["token"][0]
        first = obsidian_exports.complete(result["export_id"], token, saved_ids=[record["id"]])
        updated_at = (clip_requests.get(record["id"]) or {})["updated_at"]
        arrived = self._ready_note("https://example.com/after")
        second = obsidian_exports.complete(result["export_id"], token, saved_ids=[record["id"]])
        self.assertEqual(second["saved_ids"], [record["id"]])
        self.assertEqual(second["ok"], True)
        self.assertEqual((clip_requests.get(record["id"]) or {})["updated_at"], updated_at)
        self.assertEqual((clip_requests.get(record["id"]) or {})["obsidian_save"], "complete")
        self.assertEqual((clip_requests.get(arrived["id"]) or {})["obsidian_save"], "pending")
        self.assertEqual((clip_requests.get(arrived["id"]) or {})["note"], "# Hello\n")
        pending = {item["id"] for item in clip_requests.list_pending()}
        self.assertNotIn(record["id"], pending)
        self.assertIn(arrived["id"], pending)
        self.assertEqual(first["saved_ids"], second["saved_ids"])
        self.assertTrue((Path(self.temporary.name) / "requests" / f"{record['id']}.json").is_file())

    def test_changed_revision_and_unmentioned_export_stay_pending(self) -> None:
        changed = self._ready_note("https://example.com/changed", note="# Original\n")
        omitted = self._ready_note("https://example.com/omitted", note="# Stay\n")
        result = obsidian_exports.create(base_url="http://127.0.0.1:8003")
        token = parse_qs(urlparse(result["download_url"]).query)["token"][0]
        clip_requests.update(changed["id"], note="# Edited after export\n")
        done = obsidian_exports.complete(
            result["export_id"],
            token,
            saved_ids=[changed["id"]],
            failed_ids=[],
        )
        self.assertNotIn(changed["id"], done["saved_ids"])
        self.assertEqual(done["ok"], False)
        self.assertEqual(done["rejected"], [{"id": changed["id"], "reason": "changed"}])
        self.assertEqual((clip_requests.get(changed["id"]) or {}).get("obsidian_save"), "pending")
        self.assertEqual((clip_requests.get(changed["id"]) or {}).get("note"), "# Edited after export\n")
        self.assertEqual((clip_requests.get(omitted["id"]) or {}).get("obsidian_save"), "pending")
        self.assertEqual((clip_requests.get(omitted["id"]) or {}).get("note"), "# Stay\n")
        pending = {item["id"] for item in clip_requests.list_pending()}
        self.assertIn(changed["id"], pending)
        self.assertIn(omitted["id"], pending)

    def test_title_only_edit_is_a_changed_version(self) -> None:
        record = self._ready_note("https://example.com/title")
        result = obsidian_exports.create(base_url="http://127.0.0.1:8003")
        token = parse_qs(urlparse(result["download_url"]).query)["token"][0]
        clip_requests.update(record["id"], title="Renamed after export")
        done = obsidian_exports.complete(result["export_id"], token, saved_ids=[record["id"]])
        self.assertEqual(done["rejected"], [{"id": record["id"], "reason": "changed"}])
        self.assertEqual((clip_requests.get(record["id"]) or {}).get("obsidian_save"), "pending")
        self.assertEqual((clip_requests.get(record["id"]) or {}).get("note"), "# Hello\n")

    def test_failed_id_is_not_marked_and_stray_id_is_rejected(self) -> None:
        written = self._ready_note("https://example.com/written", note="# Written\n")
        failed = self._ready_note("https://example.com/failed-local", note="# Failed\n")
        result = obsidian_exports.create(base_url="http://127.0.0.1:8003")
        token = parse_qs(urlparse(result["download_url"]).query)["token"][0]
        done = obsidian_exports.complete(
            result["export_id"],
            token,
            saved_ids=[written["id"], written["id"], "not-in-export"],
            failed_ids=[failed["id"], "also-not-exported"],
        )
        self.assertEqual(done["saved_ids"], [written["id"]])
        self.assertEqual(done["failed_ids"], [failed["id"]])
        self.assertIn({"id": "not-in-export", "reason": "not_in_export"}, done["rejected"])
        self.assertEqual((clip_requests.get(failed["id"]) or {}).get("obsidian_save"), "pending")
        self.assertEqual((clip_requests.get(written["id"]) or {}).get("note"), "# Written\n")

    def test_legacy_export_without_revisions_can_still_be_acknowledged(self) -> None:
        record = self._ready_note("https://example.com/legacy")
        result = obsidian_exports.create(base_url="http://127.0.0.1:8003")
        token = parse_qs(urlparse(result["download_url"]).query)["token"][0]
        meta_path = Path(self.temporary.name) / "obsidian-exports" / f"{result['export_id']}.meta.json"
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        meta.pop("revisions", None)
        meta_path.write_text(json.dumps(meta), encoding="utf-8")
        done = obsidian_exports.complete(result["export_id"], token, saved_ids=[record["id"]])
        self.assertEqual(done["saved_ids"], [record["id"]])
        self.assertEqual((clip_requests.get(record["id"]) or {}).get("obsidian_save"), "complete")

    def test_callback_url_uses_the_creating_origin(self) -> None:
        self._ready_note()
        result = obsidian_exports.create(base_url="https://airtype.example:8443", vault_folder="Inbox")
        download = urlparse(result["download_url"])
        token = parse_qs(download.query)["token"][0]
        manifest = obsidian_exports.get_manifest(result["export_id"], token)
        complete = urlparse(manifest["complete"]["url"])
        self.assertEqual(download.scheme, "https")
        self.assertEqual(download.netloc, "airtype.example:8443")
        self.assertEqual(complete.scheme, download.scheme)
        self.assertEqual(complete.netloc, download.netloc)
        self.assertTrue(complete.path.endswith("/complete"))
        self.assertEqual(manifest["source"]["base_url"], "https://airtype.example:8443")
        self.assertEqual(manifest["export_id"], result["export_id"])
        self.assertIn("content_sha256", manifest["notes"][0]["revision"])


if __name__ == "__main__":
    unittest.main()
