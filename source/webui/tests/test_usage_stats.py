import json
import os
import tempfile
import unittest
from datetime import datetime, timezone

from app import usage_stats


def _write(path: str, data: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle)


class UsageStatsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.data = self.tmp.name
        records = os.path.join(self.data, "records")
        _write(
            os.path.join(records, "transcript", "20261001-100000", "record.json"),
            {
                "job_id": "20261001-100000",
                "status": "completed",
                "request": {"kind": "url", "url": "https://youtu.be/abc"},
                "details": {"article_request_chars": 1200},
                "transcript": {"text": "x" * 1000},
                "article": {"text": "polished", "request_chars": 1200},
                "created_at": "2026-10-01T02:00:00+00:00",
            },
        )
        _write(
            os.path.join(records, "transcript", "20261002-100000", "record.json"),
            {
                "job_id": "20261002-100000",
                "status": "failed",
                "error": "Could not download media URL with yt-dlp: ERROR: [BiliBili] BV1: No video formats found!",
                "request": {"kind": "url", "url": "https://b23.tv/xyz"},
                "created_at": "2026-10-02T02:00:00+00:00",
            },
        )
        _write(
            os.path.join(records, "transcript", "20261003-100000", "record.json"),
            {
                "job_id": "20261003-100000",
                "status": "completed",
                "request": {"kind": "url", "url": "https://scontent.cdninstagram.com/v/a.mp4"},
                "created_at": "2026-10-03T02:00:00+00:00",
            },
        )
        _write(
            os.path.join(records, "ime", "20261003-110000", "record.json"),
            {"job_id": "20261003-110000", "status": "completed", "result": {"duration": 5.5}, "transcript": {"text": "你好"}},
        )
        requests = os.path.join(self.data, "requests")
        # voice request linked to a transcript record: must not be double counted
        _write(os.path.join(requests, "a.json"), {"id": "a", "kind": "voice", "source": "https://youtu.be/abc", "status": "completed", "job_id": "20261001-100000"})
        _write(
            os.path.join(requests, "b.json"),
            {
                "id": "20261004-100000",
                "kind": "post",
                "source": "https://www.threads.com/share/x/",
                "status": "completed",
                "job_id": "",
                "content": "y" * 50,
                "polished_content": "z",
                "created_at": "2026-10-04T10:00:00+08:00",
            },
        )
        _write(os.path.join(requests, "c.json"), {"id": "c", "kind": "article", "source": "https://example.com/post", "status": "failed", "error": "已停止"})

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_site_normalization(self) -> None:
        self.assertEqual(usage_stats.site_for_url("https://youtu.be/x"), "YouTube")
        self.assertEqual(usage_stats.site_for_url("https://m.youtube.com/watch?v=x"), "YouTube")
        self.assertEqual(usage_stats.site_for_url("https://b23.tv/x"), "Bilibili")
        self.assertEqual(usage_stats.site_for_url("https://www.bilibili.com/video/BV1"), "Bilibili")
        self.assertEqual(usage_stats.site_for_url("https://scontent.cdninstagram.com/a"), "Instagram")
        self.assertEqual(usage_stats.site_for_url("https://www.threads.net/@a/post/b"), "Threads")
        self.assertEqual(usage_stats.site_for_url("", kind="upload"), "Upload")
        self.assertEqual(usage_stats.site_for_url("https://www.example.com/a"), "example.com")

    def test_compute_stats_aggregates_captures(self) -> None:
        stats = usage_stats.compute_stats(self.data, now=datetime(2026, 10, 5, tzinfo=timezone.utc), days=7)
        captures = stats["captures"]
        self.assertEqual(captures["total"], 5)
        self.assertEqual((captures["completed"], captures["failed"], captures["cancelled"]), (3, 1, 1))
        sites = {item["site"]: item for item in captures["by_site"]}
        self.assertEqual(sites["YouTube"]["total"], 1)
        self.assertEqual(sites["Bilibili"]["failed"], 1)
        self.assertEqual(sites["Instagram"]["completed"], 1)
        self.assertEqual(sites["Threads"]["total"], 1)
        self.assertEqual(sites["example.com"]["cancelled"], 1)
        reasons = {item["reason"]: item["count"] for item in captures["failure_reasons"]}
        self.assertEqual(reasons["找不到影片格式 (No video formats found)"], 1)
        self.assertEqual(reasons["使用者停止"], 1)
        self.assertEqual(len(captures["by_day"]), 7)
        self.assertEqual(stats["ime"]["count"], 1)
        self.assertEqual(stats["ime"]["total_duration_seconds"], 5.5)
        estimate = stats["llm"]["historical_estimate"]
        self.assertTrue(estimate["is_estimate"])
        self.assertEqual(estimate["captures"], 2)
        self.assertEqual(estimate["input_chars"], 1250)

    def test_llm_usage_log_roundtrip(self) -> None:
        payload = {"usage": {"prompt_tokens": 25, "completion_tokens": 3, "total_tokens": 28}}
        usage_stats.log_llm_usage(self.data, {"timestamp": "2026-10-05T00:00:00+00:00", "step": "polish", "model": "m", **usage_stats.usage_from_payload(payload), "input_chars": 40, "success": True})
        usage_stats.log_llm_usage(self.data, {"timestamp": "2026-10-05T00:01:00+00:00", "step": "tags", "model": "m", **usage_stats.usage_from_payload({}), "input_chars": 10, "success": False})
        llm = usage_stats.compute_stats(self.data, now=datetime(2026, 10, 5, 12, tzinfo=timezone.utc), days=7)["llm"]
        self.assertEqual(llm["totals"]["calls"], 2)
        self.assertEqual(llm["totals"]["prompt_tokens"], 25)
        self.assertEqual(llm["totals"]["calls_without_usage"], 1)
        self.assertEqual(llm["totals"]["failed_calls"], 1)
        self.assertEqual({row["step"] for row in llm["by_step"]}, {"polish", "tags"})

    def test_ollama_usage_and_logging_never_raises(self) -> None:
        tokens = usage_stats.usage_from_payload({"prompt_eval_count": 7, "eval_count": 2})
        self.assertEqual(tokens, {"prompt_tokens": 7, "completion_tokens": 2, "total_tokens": 9})
        blocker = os.path.join(self.data, "not-a-dir")
        open(blocker, "w").close()
        usage_stats.log_llm_usage(os.path.join(blocker, "sub"), {"step": "x"})  # must not raise
        usage_stats.log_llm_usage(self.data, {"bad": object()})  # unserialisable, must not raise


if __name__ == "__main__":
    unittest.main()
