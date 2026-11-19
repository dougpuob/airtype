"""Today's capture list recognizes a normalized UID and records the decision."""

from datetime import date, datetime
import tempfile
import unittest
from unittest.mock import patch

from app import clip_requests
from app import daily_captures
from app.daily_captures import DuplicateCapture
from app.main import _submit_clip_url
from app.note_id import note_guid_for_source
from app.threads_watch import _queue_into


PAGE = "https://example.com/posts/already-saved"
PAGE_WITH_TRACKING = PAGE + "?utm_source=share"


class DailyCaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        daily_captures.configure(self.temporary.name)
        clip_requests.configure(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_tracking_query_is_the_same_uid(self) -> None:
        today = date(2026, 11, 19)
        guid = daily_captures.claim(PAGE, today=today)
        found = daily_captures.lookup(PAGE_WITH_TRACKING, today=today)
        assert found is not None
        self.assertEqual(found["guid"], guid)
        self.assertEqual(guid, note_guid_for_source(PAGE))

    def test_next_day_is_not_a_duplicate(self) -> None:
        daily_captures.claim(PAGE, today=date(2026, 11, 19))
        self.assertIsNone(daily_captures.lookup(PAGE, today=date(2026, 11, 20)))

    def test_api_default_records_cancelled_and_does_not_download(self) -> None:
        daily_captures.claim(PAGE, today=date.today())
        with patch("app.main.clip_executor") as executor:
            record = _submit_clip_url(PAGE_WITH_TRACKING)
        executor.submit.assert_not_called()
        self.assertEqual(record["status"], "duplicate_cancelled")
        self.assertEqual(record["message"], "Duplicate cancelled")
        self.assertEqual(record["duplicate"], "cancelled")
        self.assertEqual(record["guid"], note_guid_for_source(PAGE))
        self.assertIn(record["guid"], record["error"])
        stored = clip_requests.get(record["id"])
        assert stored is not None
        self.assertEqual(stored["status"], "duplicate_cancelled")

    def test_confirm_records_proceeded_and_starts_the_download(self) -> None:
        daily_captures.claim(PAGE, today=date.today())
        with patch("app.main.clip_executor") as executor:
            record = _submit_clip_url(PAGE, confirm_duplicate=True)
        executor.submit.assert_called_once()
        self.assertEqual(record["duplicate"], "proceeded")
        self.assertEqual(record["message"], "Duplicate continued")
        self.assertEqual(record["guid"], note_guid_for_source(PAGE))
        self.assertNotEqual(record["status"], "duplicate_cancelled")

    def test_claim_reports_the_existing_entry(self) -> None:
        daily_captures.claim(PAGE, today=date(2026, 11, 19), now=datetime(2026, 11, 19, 9, 0).astimezone())
        with self.assertRaises(DuplicateCapture) as ctx:
            daily_captures.claim(PAGE, today=date(2026, 11, 19))
        self.assertEqual(ctx.exception.guid, note_guid_for_source(PAGE))
        self.assertEqual(ctx.exception.existing["url"], PAGE)


class WatchDuplicateTests(unittest.TestCase):
    def test_cancelled_duplicate_is_not_a_queue_failure(self) -> None:
        entry = {"url": PAGE}
        failures: list[str] = []
        queued = _queue_into(
            entry,
            lambda url: {
                "id": "20261119-210000",
                "status": "duplicate_cancelled",
                "duplicate": "cancelled",
                "message": "Duplicate cancelled",
            },
            failures,
        )
        self.assertEqual(queued, 0)
        self.assertEqual(failures, [])
        self.assertEqual(entry["status"], "duplicate")
        self.assertEqual(entry["clip_request_id"], "20261119-210000")
        self.assertIn("Duplicate cancelled", entry["error"])
