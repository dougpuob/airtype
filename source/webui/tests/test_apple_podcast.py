"""Apple Podcasts episode resolution and original-content order."""

import unittest

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
