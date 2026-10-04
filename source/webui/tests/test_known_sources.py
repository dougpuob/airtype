"""Tests for the known-source routing list."""

import unittest

from app import known_sources


class KnownSourceRoutingTests(unittest.TestCase):
    def test_threads_hosts_match_with_subdomains(self) -> None:
        self.assertEqual(
            known_sources.match_known_source("https://www.threads.com/@user/post/123").pipeline,
            "capture-post",
        )
        self.assertEqual(
            known_sources.match_known_source("https://threads.net/@user/post/123").pipeline,
            "capture-post",
        )

    def test_youtube_hosts_and_shorts(self) -> None:
        self.assertEqual(
            known_sources.match_known_source("https://www.youtube.com/watch?v=abc").pipeline,
            "v-to-text",
        )
        self.assertEqual(
            known_sources.match_known_source("https://youtu.be/abc").pipeline,
            "v-to-text",
        )
        self.assertEqual(
            known_sources.route_for_url("https://example.com/shorts/abc"),
            "v-to-text",
        )

    def test_bilibili_short_link(self) -> None:
        self.assertEqual(
            known_sources.match_known_source("https://b23.tv/abc").pipeline,
            "v-to-text",
        )

    def test_instagram_and_tiktok(self) -> None:
        self.assertEqual(
            known_sources.match_known_source("https://www.instagram.com/reel/abc/").pipeline,
            "v-to-text",
        )
        self.assertEqual(
            known_sources.match_known_source("https://www.tiktok.com/@user/video/1").pipeline,
            "v-to-text",
        )

    def test_lookalike_domains_never_match(self) -> None:
        self.assertIsNone(known_sources.match_known_source("https://notyoutube.com/watch?v=abc"))
        self.assertIsNone(known_sources.match_known_source("https://youtube.com.evil.io/watch"))
        self.assertIsNone(known_sources.match_known_source("https://fakebilibili.com/video"))
        self.assertIsNone(known_sources.match_known_source("https://xthreads.com/post/1"))

    def test_unknown_host_routes_to_web_article(self) -> None:
        self.assertEqual(
            known_sources.route_for_url("https://blog.example.com/post/1"),
            known_sources.WEB_ARTICLE_PIPELINE,
        )

    def test_media_file_extension_routes_to_v_to_text(self) -> None:
        self.assertEqual(
            known_sources.route_for_url("https://cdn.example.com/audio/ep1.mp3"),
            "v-to-text",
        )
        self.assertEqual(
            known_sources.route_for_url("https://cdn.example.com/audio/ep1.MP3?query=1"),
            "v-to-text",
        )
        self.assertEqual(
            known_sources.route_for_url("https://cdn.example.com/video/ep1.webm"),
            "v-to-text",
        )

    def test_ports_and_case_are_ignored(self) -> None:
        self.assertEqual(
            known_sources.match_known_source("https://YouTube.COM:8443/watch?v=abc").pipeline,
            "v-to-text",
        )

    def test_invalid_urls_route_to_web_article(self) -> None:
        self.assertEqual(known_sources.route_for_url(""), known_sources.WEB_ARTICLE_PIPELINE)
        self.assertEqual(known_sources.route_for_url("not a url"), known_sources.WEB_ARTICLE_PIPELINE)

    def test_hint_text_for_known_source(self) -> None:
        hint = known_sources.known_source_hint("https://www.threads.com/@a/post/1")
        self.assertIn("Capture Post", hint)
        self.assertIn("threads.com", hint)
        self.assertEqual(known_sources.known_source_hint("https://blog.example.com/"), "")
        self.assertIn("V-to-Text", known_sources.known_source_hint("https://x.com/a/ep1.mp3"))

    def test_payload_lists_every_host(self) -> None:
        payload = known_sources.known_sources_payload()
        hosts = [entry["host"] for entry in payload["sources"]]
        self.assertIn("threads.com", hosts)
        self.assertIn("b23.tv", hosts)
        self.assertIn(".mp3", payload["media_file_extensions"])
        self.assertEqual(payload["web_article_pipeline"], "web-article")


if __name__ == "__main__":
    unittest.main()