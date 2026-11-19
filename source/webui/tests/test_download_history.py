import json
import tempfile
import unittest
from pathlib import Path

from app import download_history as history


def _row(request_id, **extra):
    record = {
        "id": request_id,
        "status": "completed",
        "source": f"https://example.com/{request_id}",
        "guid": f"00000000-0000-4000-8000-{request_id[-12:].zfill(12)}",
        "title": "A downloaded page",
        "kind": "article",
        "origin": "manual",
        "message": "Completed",
        "created_at": "2026-07-01T10:00:00+08:00",
        "updated_at": "2026-07-01T10:05:00+08:00",
        "datetime": "2026-06-30T09:00:00+08:00",
    }
    record.update(extra)
    return record


class DownloadHistoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        history.configure(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_only_finished_requests_are_stored(self):
        history.note(_row("queued-one", status="queued"))
        history.note(_row("done-one"))
        found = history.search()
        self.assertEqual(found["total"], 1)
        self.assertEqual(found["items"][0]["request_id"], "done-one")
        self.assertEqual(found["items"][0]["url"], "https://example.com/done-one")
        self.assertEqual(found["items"][0]["content_at"], "2026-06-30T09:00:00+08:00")
        self.assertEqual(found["page_size"], 100)

    def test_keyword_matches_uuid_url_and_title(self):
        history.note(_row("aaa", guid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", title="House listing", source="https://sale.591.com.tw/home/1"))
        history.note(_row("bbb", guid="11111111-2222-3333-4444-555555555555", title="Other note", source="https://example.com/other"))
        by_uuid = history.search("eeeeeeeeeeee")
        self.assertEqual([item["request_id"] for item in by_uuid["items"]], ["aaa"])
        by_url = history.search("591.com.tw house")
        self.assertEqual([item["request_id"] for item in by_url["items"]], ["aaa"])
        self.assertEqual(history.search("missing-word").get("total"), 0)

    def test_pages_default_to_100_and_can_be_smaller(self):
        for index in range(3):
            history.note(_row(f"item-{index}", updated_at=f"2026-07-0{index + 1}T10:00:00+08:00"))
        first = history.search("", page=1, page_size=2)
        self.assertEqual(first["total"], 3)
        self.assertEqual(first["pages"], 2)
        self.assertEqual(len(first["items"]), 2)
        self.assertEqual(first["items"][0]["request_id"], "item-2")
        second = history.search("", page=2, page_size=2)
        self.assertEqual([item["request_id"] for item in second["items"]], ["item-0"])
        fallback = history.search("", page_size=0)
        self.assertEqual(fallback["page_size"], 100)
        self.assertEqual(len(fallback["items"]), 3)

    def test_later_title_fills_in_without_moving_the_finished_time(self):
        history.note(_row("same", title=""))
        history.note(_row("same", title="Filled in later", updated_at="2026-08-01T00:00:00+08:00"))
        item = history.search()["items"][0]
        self.assertEqual(item["title"], "Filled in later")
        self.assertEqual(item["finished_at"], "2026-07-01T10:05:00+08:00")

    def test_backfill_reads_finished_request_files(self):
        root = Path(self.tmp.name) / "requests"
        root.mkdir()
        (root / "ok.json").write_text(json.dumps(_row("from-file")), encoding="utf-8")
        (root / "still.json").write_text(json.dumps(_row("running", status="running")), encoding="utf-8")
        (root / "bad.json").write_text("{", encoding="utf-8")
        self.assertEqual(history.backfill_requests(root), 1)
        self.assertEqual(history.search()["items"][0]["request_id"], "from-file")
        self.assertEqual(history.backfill_requests(root), 1)
        self.assertEqual(history.search()["total"], 1)


if __name__ == "__main__":
    unittest.main()
