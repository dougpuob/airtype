"""Apple Podcasts episode resolution and original-content order."""

import unittest
from unittest import mock

from app import apple_podcast
from app import main as webui


EPISODE_URL = "https://podcasts.apple.com/tw/podcast/ep706/id1500839292?i=1000796775119"
NOTES = "跳跳車\n\n眠豆腐官網：https://link.sleepytofu.com/gooaye_sesametofu"
AUDIO = "https://rss.soundon.fm/rssf/show/feedurl/episode/rssFileVip.mp3?timestamp=1"


def _lookup_hit() -> dict:
    return {
        "resultCount": 2,
        "results": [
            {
                "kind": "podcast",
                "trackId": 1500839292,
                "feedUrl": "https://feeds.example.com/show.xml",
            },
            {
                "kind": "podcast-episode",
                "trackId": 1000796775119,
                "trackName": "EP706 | 👑",
                "description": NOTES,
                "episodeUrl": AUDIO,
            },
        ],
    }


def _lookup_miss() -> dict:
    return {
        "resultCount": 1,
        "results": [
            {
                "kind": "podcast",
                "trackId": 1500839292,
                "feedUrl": "https://feeds.example.com/show.xml",
            }
        ],
    }


FEED = """<?xml version="1.0" encoding="UTF-8"?>
<rss>
  <channel>
    <item>
      <title>EP700 | older</title>
      <guid>other-guid</guid>
      <description>older notes</description>
      <enclosure url="https://cdn.example.com/ep700.mp3" type="audio/mpeg"/>
    </item>
    <item>
      <title>EP706 | 👑</title>
      <guid>b815e52b-b0b9-47d2-980b-baf1857cd604</guid>
      <description><![CDATA[<p>跳跳車</p><p>眠豆腐官網：https://link.sleepytofu.com/gooaye_sesametofu</p>]]></description>
      <enclosure url="https://cdn.example.com/ep706.mp3" type="audio/mpeg"/>
    </item>
  </channel>
</rss>
"""

FEED_BY_GUID = """<?xml version="1.0" encoding="UTF-8"?>
<rss>
  <channel>
    <item>
      <title>Something else</title>
      <guid>1000796775119</guid>
      <description>guid notes</description>
      <enclosure url="https://cdn.example.com/by-guid.mp3"/>
    </item>
    <item>
      <title>EP706 | decoy</title>
      <guid>decoy</guid>
      <description>slug notes</description>
      <enclosure url="https://cdn.example.com/by-slug.mp3"/>
    </item>
  </channel>
</rss>
"""


class AppleEpisodeResolutionTests(unittest.TestCase):
    def test_parse_episode_url(self) -> None:
        self.assertEqual(
            apple_podcast.parse_episode_url(EPISODE_URL),
            ("1500839292", "1000796775119", "ep706"),
        )
        self.assertIsNone(apple_podcast.parse_episode_url("https://podcasts.apple.com/tw/podcast/show/id1500839292"))
        self.assertIsNone(apple_podcast.parse_episode_url("https://example.com/podcast/ep706/id1?i=2"))

    def test_lookup_hit_uses_episode_audio_and_notes(self) -> None:
        fetched: list[str] = []
        episode = apple_podcast.resolve_episode(
            EPISODE_URL,
            lookup=lambda show_id: _lookup_hit(),
            fetch_feed=lambda url: fetched.append(url) or "",
        )
        self.assertEqual(episode.title, "EP706 | 👑")
        self.assertEqual(episode.description, NOTES)
        self.assertEqual(episode.audio_url, AUDIO)
        self.assertEqual(fetched, [])

    def test_lookup_miss_falls_back_to_rss_slug(self) -> None:
        episode = apple_podcast.resolve_episode(
            EPISODE_URL,
            lookup=lambda show_id: _lookup_miss(),
            fetch_feed=lambda url: FEED,
        )
        self.assertEqual(episode.audio_url, "https://cdn.example.com/ep706.mp3")
        self.assertIn("跳跳車", episode.description)
        self.assertNotIn("<p>", episode.description)

    def test_rss_guid_wins_over_slug(self) -> None:
        episode = apple_podcast.resolve_episode(
            EPISODE_URL,
            lookup=lambda show_id: _lookup_miss(),
            fetch_feed=lambda url: FEED_BY_GUID,
        )
        self.assertEqual(episode.audio_url, "https://cdn.example.com/by-guid.mp3")
        self.assertEqual(episode.description, "guid notes")

    def test_missing_episode_fails(self) -> None:
        with self.assertRaises(apple_podcast.AppleEpisodeError):
            apple_podcast.resolve_episode(
                "https://podcasts.apple.com/tw/podcast/show/id1500839292",
                lookup=lambda show_id: _lookup_hit(),
            )
        with self.assertRaises(apple_podcast.AppleEpisodeError):
            apple_podcast.resolve_episode(
                EPISODE_URL,
                lookup=lambda show_id: {"results": [{"feedUrl": "https://feeds.example.com/show.xml"}]},
                fetch_feed=lambda url: "<rss></rss>",
            )

    def test_original_content_puts_notes_above_transcript(self) -> None:
        combined = apple_podcast.original_content("節目敘述", "主字稿第一句")
        self.assertEqual(combined, "節目敘述\n\n主字稿第一句")
        self.assertLess(combined.index("節目敘述"), combined.index("主字稿第一句"))
        self.assertEqual(apple_podcast.original_content("", "只有逐字稿"), "只有逐字稿")

    def test_transcript_keeps_one_line_per_asr_segment(self) -> None:
        text = webui._record_transcript_text(
            {
                "transcript": {
                    "text": "第一句 第二句",
                    "segments": [{"text": " 第一句 "}, {"text": "第二句"}],
                }
            }
        )
        self.assertEqual(text, "第一句\n第二句")
        note = webui._note_transcript(text)
        self.assertEqual(note, "第一句    \n第二句")

    def test_typo_correction_chunks_long_transcripts_and_keeps_bad_rewrites(self) -> None:
        lines = [f"第{index}句錯自" for index in range(5)]
        chunks = webui._chunk_transcript_lines(lines, limit=8)
        self.assertGreater(len(chunks), 1)
        self.assertEqual([line for chunk in chunks for line in chunk], lines)
        self.assertEqual(webui._accepted_typo_lines(["錯自"], "錯字"), ["錯字"])
        self.assertEqual(webui._accepted_typo_lines(["錯自", "第二句"], "錯字"), ["錯自", "第二句"])
        self.assertEqual(webui._accepted_typo_lines(["錯自"], "```\n錯字\n```"), ["錯字"])

    def test_asr_result_keeps_corrected_lines_on_each_segment(self) -> None:
        result = webui._correct_asr_result(
            "missing-job",
            {"text": "錯自\n第二句", "segments": [{"text": " 錯自 "}, {"text": "第二句"}]},
            correct_chunk=lambda job_id, chunk, reference="": "\n".join(
                "錯字" if line == "錯自" else line for line in chunk
            ),
            reference="",
        )
        self.assertEqual(result["text"], "錯字\n第二句")
        self.assertEqual([segment["text"] for segment in result["segments"]], ["錯字", "第二句"])

    def test_typo_review_rejects_only_bad_lines(self) -> None:
        source = ["歡迎收聽古欸", "今天天氣很好我們來聊聊股票市場", "好"]
        corrected = "歡迎收聽股癌\n短\n好的"
        lines, reason, rejected = webui._review_typo_lines(source, corrected)
        self.assertEqual(reason, "line-length")
        self.assertEqual(rejected, [1])
        self.assertEqual(lines, ["歡迎收聽股癌", "今天天氣很好我們來聊聊股票市場", "好的"])
        lines, reason, rejected = webui._review_typo_lines(source, "歡迎收聽股癌\n只有兩行")
        self.assertEqual(reason, "line-count")
        self.assertEqual(lines, source)
        lines, reason, rejected = webui._review_typo_lines(["錯自"], "錯字")
        self.assertEqual((lines, reason, rejected), (["錯字"], "", []))

    def test_typo_line_count_mismatch_retries_once_then_keeps_original(self) -> None:
        calls: list[str] = []
        replies = iter(["只有一行", "股癌\n第二句"])

        def fake(job_id, chunk, reference=""):
            calls.append(reference)
            return next(replies)

        with mock.patch.object(webui, "append_service_log") as log:
            result = webui._correct_transcript_lines("job-x", ["古欸", "第二句"], correct_chunk=fake, reference="REF")
        self.assertEqual(result, ["股癌", "第二句"])
        self.assertEqual(calls, ["REF", "REF"])
        self.assertTrue(any("reason=line-count" in str(call) for call in log.call_args_list))

        with mock.patch.object(webui, "append_service_log") as log:
            result = webui._correct_transcript_lines(
                "job-x", ["古欸", "第二句"], correct_chunk=lambda j, c, r="": "一行"
            )
        self.assertEqual(result, ["古欸", "第二句"])
        self.assertTrue(any("kept original chunk" in str(call) for call in log.call_args_list))

    def test_typo_reference_context_and_prompt(self) -> None:
        metadata = {
            "title": "EP707",
            "uploader": "Gooaye 股癌",
            "webpage_url": "https://podcasts.apple.com/tw/podcast/gooaye-%E8%82%A1%E7%99%8C/id1",
            "tags": ["股癌", "投資"],
            "description": "股癌 gooaye " + "x" * 5000,
        }
        reference = webui._typo_reference_context(metadata)
        self.assertIn("標題：EP707", reference)
        self.assertIn("上傳者：Gooaye 股癌", reference)
        self.assertIn("gooaye-股癌", reference)
        self.assertIn("標籤：股癌、投資", reference)
        self.assertLess(len(reference), webui.TYPO_REFERENCE_DESCRIPTION_CHARS + 400)
        self.assertEqual(webui._typo_reference_context(None), "")
        prompt = webui._typo_user_prompt("古欸", reference)
        self.assertIn("參考資料", prompt)
        self.assertIn("不得把其中的內容抄進逐字稿", prompt)
        self.assertTrue(prompt.rstrip().endswith("古欸"))
        plain = webui._typo_user_prompt("古欸")
        self.assertNotIn("參考資料", plain)
        self.assertNotIn("{", plain)

    def test_asr_result_uses_job_source_metadata_as_reference(self) -> None:
        seen: list[str] = []

        def fake(job_id, chunk, reference=""):
            seen.append(reference)
            return "\n".join(chunk)

        with mock.patch.dict(
            webui.transcription_jobs,
            {"job-meta": {"source_metadata": {"title": "EP707", "description": "股癌 gooaye"}}},
        ), mock.patch.object(webui, "_is_job_cancelled", return_value=False), mock.patch.object(webui, "_update_job"):
            webui._correct_asr_result("job-meta", {"text": "古欸", "segments": [{"text": "古欸"}]}, correct_chunk=fake)
        self.assertEqual(len(seen), 1)
        self.assertIn("股癌 gooaye", seen[0])

    def test_typo_chunks_run_concurrently_in_order(self) -> None:
        import threading
        import time as _time

        lines = [f"第{index}句錯自" for index in range(40)]
        active = {"now": 0, "max": 0}
        lock = threading.Lock()

        def fake(job_id, chunk, reference=""):
            with lock:
                active["now"] += 1
                active["max"] = max(active["max"], active["now"])
            _time.sleep(0.05)
            with lock:
                active["now"] -= 1
            return "\n".join(line.replace("錯自", "錯字") for line in chunk)

        with mock.patch.object(webui, "TYPO_CHUNK_CHARS", 20), mock.patch.object(
            webui, "_chunk_transcript_lines", lambda spoken: [spoken[i:i + 3] for i in range(0, len(spoken), 3)]
        ):
            result = webui._correct_transcript_lines("job-c", lines, correct_chunk=fake, concurrency=4)
        self.assertEqual(result, [line.replace("錯自", "錯字") for line in lines])
        self.assertGreater(active["max"], 1)
        self.assertLessEqual(active["max"], 4)

    def test_typo_concurrency_honours_cancellation_and_failures(self) -> None:
        lines = ["甲錯自", "乙錯自", "丙錯自", "丁錯自"]

        def fake(job_id, chunk, reference=""):
            if chunk[0].startswith("乙"):
                raise RuntimeError("boom")
            return "\n".join(line.replace("錯自", "錯字") for line in chunk)

        chunker = lambda spoken: [[line] for line in spoken]
        with mock.patch.object(webui, "_chunk_transcript_lines", chunker), mock.patch.object(
            webui, "append_service_log"
        ) as log:
            result = webui._correct_transcript_lines("job-f", lines, correct_chunk=fake, concurrency=3)
        self.assertEqual(result, ["甲錯字", "乙錯自", "丙錯字", "丁錯字"])
        self.assertTrue(any("kept original chunk" in str(call) for call in log.call_args_list))

        calls = []
        with mock.patch.object(webui, "_chunk_transcript_lines", chunker), mock.patch.object(
            webui, "_is_job_cancelled", return_value=True
        ):
            result = webui._correct_transcript_lines(
                "job-x", lines, correct_chunk=lambda j, c, r="": calls.append(c) or "x", concurrency=3
            )
        self.assertEqual(result, lines)
        self.assertEqual(calls, [])

    def test_grok_correct_step_retries_timeout_and_never_falls_back(self) -> None:
        from app import grok_cli

        settings = {**grok_cli.DEFAULT_GROK_CLI_SETTINGS, "enabled": True, "timeout_seconds": 300}
        request = webui.LocalChatRequest(
            provider="openai", endpoint="http://x", model="m", system="s", prompt="p", step="correct"
        )
        seen = []

        def timeouts(system, prompt, settings, timeout=None):
            seen.append(timeout)
            raise grok_cli.GrokTimeout("grok timed out")

        with mock.patch.object(grok_cli, "read_grok_cli_settings", return_value=settings), mock.patch.object(
            grok_cli, "run_grok_cli", side_effect=timeouts
        ), mock.patch.object(webui, "_record_llm_usage"), mock.patch.object(webui, "append_service_log"), \
                mock.patch.object(webui, "_local_chat_completion") as local:
            with self.assertRaises(webui.GrokCorrectFailed):
                webui._local_chat_response(request)
            local.assert_not_called()
        self.assertEqual(seen, [180, 180])

        replies = iter([grok_cli.GrokTimeout("t"), ("修好", {"usage": {}})])

        def flaky(system, prompt, settings, timeout=None):
            reply = next(replies)
            if isinstance(reply, Exception):
                raise reply
            return reply

        with mock.patch.object(grok_cli, "read_grok_cli_settings", return_value=settings), mock.patch.object(
            grok_cli, "run_grok_cli", side_effect=flaky
        ), mock.patch.object(webui, "_record_llm_usage"), mock.patch.object(webui, "append_service_log"):
            self.assertEqual(webui._local_chat_response(request), "修好")

    def test_grok_other_steps_still_fall_back_with_long_timeout(self) -> None:
        from app import grok_cli

        settings = {**grok_cli.DEFAULT_GROK_CLI_SETTINGS, "enabled": True, "timeout_seconds": 300}
        request = webui.LocalChatRequest(
            provider="openai", endpoint="http://x", model="m", system="s", prompt="p", step="polish"
        )
        seen = []

        def fails(system, prompt, settings, timeout=None):
            seen.append(timeout)
            raise RuntimeError("not signed in")

        with mock.patch.object(grok_cli, "read_grok_cli_settings", return_value=settings), mock.patch.object(
            grok_cli, "run_grok_cli", side_effect=fails
        ), mock.patch.object(webui, "_record_llm_usage"), mock.patch.object(webui, "append_service_log"):
            self.assertIsNone(webui._grok_cli_response(request))
        self.assertEqual(seen, [300])

    def test_voice_clip_source_keeps_apple_notes_above_transcript(self) -> None:
        combined = webui._voice_clip_source_text(
            {"episode_preface": "節目敘述", "source_metadata": {}},
            "主字稿第一句",
        )
        self.assertTrue(combined.startswith("節目敘述\n\n"))
        self.assertTrue(combined.endswith("主字稿第一句"))
        self.assertEqual(
            webui._voice_clip_source_text(
                {"source_metadata": {"description": "YouTube description", "download_method": "yt-dlp-audio"}},
                "逐字稿",
            ),
            "逐字稿",
        )


if __name__ == "__main__":
    unittest.main()
