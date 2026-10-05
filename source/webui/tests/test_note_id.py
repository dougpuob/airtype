"""Tests for canonical source IDs and UUID v5 clip GUIDs."""

import unittest
import uuid

from app.note_id import CLIP_NAMESPACE, canonical_source_id, note_guid_for_source


class CanonicalSourceIdTests(unittest.TestCase):
    def test_youtube_aliases_share_one_id(self) -> None:
        expected = "youtube:dQw4w9WgXcQ"
        urls = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=30s",
            "https://www.youtube.com/shorts/dQw4w9WgXcQ",
            "https://m.youtube.com/embed/dQw4w9WgXcQ",
            "https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=abc",
        ]
        for url in urls:
            self.assertEqual(canonical_source_id(url), expected, url)

    def test_threads_post_aliases(self) -> None:
        expected = "threads:@alice/post/DZ7jXhqj-rV"
        self.assertEqual(
            canonical_source_id("https://www.threads.com/@Alice/post/DZ7jXhqj-rV"),
            expected,
        )
        self.assertEqual(
            canonical_source_id("https://threads.net/@alice/post/DZ7jXhqj-rV/"),
            expected,
        )
        self.assertEqual(
            canonical_source_id("https://www.threads.com/share/HjFW63xVh/"),
            "threads:share/HjFW63xVh",
        )

    def test_bilibili_keeps_non_default_part(self) -> None:
        self.assertEqual(
            canonical_source_id("https://www.bilibili.com/video/BV1xx411c7mD?spm_id_from=333"),
            "bilibili:BV1xx411c7mD",
        )
        self.assertEqual(
            canonical_source_id("https://www.bilibili.com/video/BV1xx411c7mD?p=2"),
            "bilibili:BV1xx411c7mD/p2",
        )

    def test_instagram_and_tiktok(self) -> None:
        self.assertEqual(
            canonical_source_id("https://www.instagram.com/reel/AbC123/?igshid=xyz"),
            "instagram:AbC123",
        )
        self.assertEqual(
            canonical_source_id("https://www.tiktok.com/@user/video/1234567890?pp=1"),
            "tiktok:1234567890",
        )

    def test_web_drops_tracking_fragment_and_trailing_slash(self) -> None:
        self.assertEqual(
            canonical_source_id("http://WWW.Example.com/2024/hello-world/?utm_source=x#section"),
            "web:https://www.example.com/2024/hello-world",
        )
        self.assertEqual(
            canonical_source_id("https://www.example.com/2024/hello-world"),
            canonical_source_id("https://www.example.com/2024/hello-world/?fbclid=1"),
        )

    def test_lookalike_youtube_stays_web(self) -> None:
        self.assertTrue(
            canonical_source_id("https://notyoutube.com/watch?v=abc").startswith("web:")
        )

    def test_empty_or_invalid_has_no_identity(self) -> None:
        self.assertEqual(canonical_source_id(""), "")
        self.assertEqual(canonical_source_id("not a url"), "")


class NoteGuidTests(unittest.TestCase):
    def test_v5_is_stable_and_version_5(self) -> None:
        url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        guid = note_guid_for_source(url)
        self.assertEqual(guid, note_guid_for_source("https://youtu.be/dQw4w9WgXcQ"))
        parsed = uuid.UUID(guid)
        self.assertEqual(parsed.version, 5)
        self.assertEqual(guid, str(uuid.uuid5(CLIP_NAMESPACE, "youtube:dQw4w9WgXcQ")))

    def test_frozen_youtube_guid(self) -> None:
        self.assertEqual(
            note_guid_for_source("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
            "3da83937-e632-5d26-bf1f-616d39d6b975",
        )

    def test_different_sources_differ(self) -> None:
        self.assertNotEqual(
            note_guid_for_source("https://www.youtube.com/watch?v=aaaaaaaaaaa"),
            note_guid_for_source("https://www.youtube.com/watch?v=bbbbbbbbbbb"),
        )

    def test_invalid_url_falls_back_to_uuid4(self) -> None:
        first = note_guid_for_source("")
        second = note_guid_for_source("")
        self.assertEqual(uuid.UUID(first).version, 4)
        self.assertNotEqual(first, second)


if __name__ == "__main__":
    unittest.main()
