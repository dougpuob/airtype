"""Instagram posts and reels go through Capture Post: caption, photos, Whisper."""

from unittest.mock import patch
import os
import tempfile
import unittest

from app import clip_pipeline
from app import clip_requests
from app import instagram_weaver
from app import main as webui


POST_URL = "https://www.instagram.com/p/DfFNi8dAcO6/?cplk=Z2kyNm43bWs4N2pm"
CANONICAL = "https://www.instagram.com/p/DfFNi8dAcO6/"
PHOTO = "https://scontent.cdninstagram.com/v/t51/photo_n.jpg?stp=1"
PHOTO_SMALL = "https://scontent.cdninstagram.com/v/t51/photo_s.jpg?stp=2"
COVER = "https://scontent.cdninstagram.com/v/t51/cover_n.jpg?stp=3"
VIDEO = "https://instagram.ftpe8-4.fna.fbcdn.net/o1/v/t16/f2/m84/AQPvideo?efg=1"
VIDEO_LOW = "https://instagram.ftpe8-4.fna.fbcdn.net/o1/v/t16/f2/m84/AQPlow?efg=2"
SETTINGS = {"web_to_markdown": {}, "immich": {}, "capture_post": {"ai_title_enabled": False}}


def _image(url: str, width: int = 1080) -> dict:
    return {"image_versions2": {"candidates": [
        {"url": PHOTO_SMALL, "width": 320, "height": 320},
        {"url": url, "width": width, "height": width},
    ]}}


PHOTO_NODE = {
    "code": "DfFNi8dAcO6",
    "media_type": 1,
    "taken_at": 1793283756,
    "user": {"username": "hkepc", "full_name": "HKEPC"},
    "caption": {"text": "【立即斷線⚠️】Synology NAS 遭勒索 &amp; 加密"},
    **_image(PHOTO),
}

CAROUSEL_NODE = {
    "code": "BQ0eAlwhDrw",
    "media_type": 8,
    "user": {"username": "instagram"},
    "caption": {"text": "Swipe left"},
    "carousel_media": [
        _image(PHOTO),
        {**_image(COVER), "video_versions": [
            {"url": VIDEO_LOW, "width": 480, "height": 480},
            {"url": VIDEO, "width": 720, "height": 720},
        ]},
    ],
}


class InstagramUrlTests(unittest.TestCase):
    def test_post_urls(self) -> None:
        for url, code in (
            (POST_URL, "DfFNi8dAcO6"),
            ("https://instagram.com/reel/Chunk8-jurw", "Chunk8-jurw"),
            ("https://www.instagram.com/reels/Cop84x6u7CP/", "Cop84x6u7CP"),
            ("https://www.instagram.com/tv/BkfuX9UB-eK/", "BkfuX9UB-eK"),
            ("https://www.instagram.com/hkepc/p/DfFNi8dAcO6/", "DfFNi8dAcO6"),
        ):
            self.assertEqual(instagram_weaver.instagram_shortcode(url), code, url)
        self.assertEqual(instagram_weaver.canonical_instagram_url(POST_URL), CANONICAL)
        self.assertEqual(
            instagram_weaver.canonical_instagram_url("https://www.instagram.com/reels/Cop84x6u7CP/?x=1"),
            "https://www.instagram.com/reel/Cop84x6u7CP/",
        )

    def test_non_post_urls(self) -> None:
        for url in (
            "https://www.instagram.com/hkepc/",
            "https://www.instagram.com/stories/hkepc/123/",
            "https://notinstagram.com/p/DfFNi8dAcO6/",
            "https://www.threads.com/@a/post/DfFNi8dAcO6",
        ):
            self.assertFalse(instagram_weaver.is_instagram_post_url(url), url)


class MediaNodeTests(unittest.TestCase):
    def test_photo_post(self) -> None:
        post = instagram_weaver.post_from_media_node(PHOTO_NODE, CANONICAL)
        self.assertEqual(post["author"], "hkepc")
        self.assertEqual(post["shortcode"], "DfFNi8dAcO6")
        self.assertEqual(post["text"], "【立即斷線⚠️】Synology NAS 遭勒索 & 加密")
        self.assertEqual(post["image_urls"], [PHOTO])  # largest candidate only
        self.assertEqual(post["videos"], [])
        self.assertEqual(post["taken_at"], 1793283756)

    def test_carousel_keeps_photos_and_videos_in_order(self) -> None:
        post = instagram_weaver.post_from_media_node(CAROUSEL_NODE, CANONICAL)
        self.assertEqual(post["image_urls"], [PHOTO, COVER])
        self.assertEqual(post["videos"], [{"video_url": VIDEO, "cover_url": COVER, "has_audio": True}])

    def test_public_first_then_cookies(self) -> None:
        calls: list[dict] = []

        def fetch(url, options):
            calls.append(options)
            if not options:
                raise instagram_weaver.InstagramCaptureError("empty media response")
            return PHOTO_NODE

        post = instagram_weaver.fetch_instagram_post(POST_URL, cookies_path="/c.txt", media_node_fn=fetch)
        self.assertEqual(calls, [{}, {"cookiefile": "/c.txt"}])
        self.assertEqual(post["url"], CANONICAL)

    def test_public_post_needs_no_cookies(self) -> None:
        calls: list[dict] = []
        instagram_weaver.fetch_instagram_post(
            POST_URL, cookies_from_browser="chrome", media_node_fn=lambda _u, o: calls.append(o) or PHOTO_NODE
        )
        self.assertEqual(calls, [{}])

    def test_failure_is_clear(self) -> None:
        def fetch(_url, _options):
            raise instagram_weaver.InstagramCaptureError("login required")

        with self.assertRaisesRegex(instagram_weaver.InstagramCaptureError, "private, login-only"):
            instagram_weaver.fetch_instagram_post(POST_URL, media_node_fn=fetch)


class LoadInstagramPostTests(unittest.TestCase):
    def _load(self, node: dict) -> dict:
        def fake(url, **_kwargs):
            return instagram_weaver.post_from_media_node(node, instagram_weaver.canonical_instagram_url(url))

        with (
            patch.object(webui.instagram_weaver, "fetch_instagram_post", side_effect=fake),
            patch.object(webui, "_read_backend_config_settings", return_value={"ytdlp": {}}),
        ):
            return webui._load_public_post(POST_URL)

    def test_photo_payload(self) -> None:
        payload = self._load(PHOTO_NODE)
        self.assertEqual(payload["post_url"], CANONICAL)
        self.assertEqual(payload["media_urls"], [PHOTO])
        self.assertEqual(payload["videos"], [])
        self.assertIn("Synology NAS", payload["markdown"])
        self.assertIn(f"![]({PHOTO})", payload["markdown"])

    def test_video_payload(self) -> None:
        payload = self._load(CAROUSEL_NODE)
        self.assertEqual(payload["videos"], [{"post_url": CANONICAL, "video_url": VIDEO}])


class SilentVideoTests(unittest.TestCase):
    def test_video_without_sound_is_not_sent_to_whisper(self) -> None:
        node = {**CAROUSEL_NODE, "carousel_media": [
            {**item, "has_audio": False} for item in CAROUSEL_NODE["carousel_media"]
        ]}
        post = instagram_weaver.post_from_media_node(node, CANONICAL)
        self.assertFalse(post["videos"][0]["has_audio"])
        with (
            patch.object(webui.instagram_weaver, "fetch_instagram_post", return_value=post),
            patch.object(webui, "_read_backend_config_settings", return_value={"ytdlp": {}}),
        ):
            payload = webui._load_public_post(POST_URL)
        self.assertEqual(payload["videos"], [])
        self.assertEqual(payload["media_urls"], [PHOTO, COVER])


class RunInstagramPostTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        clip_requests.configure(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_photos_to_immich_and_video_transcript_in_same_note(self) -> None:
        payload = {
            "url": POST_URL,
            "post_url": CANONICAL,
            "text": "Swipe left",
            "markdown": f"Swipe left\n\n![]({PHOTO})\n\n![]({COVER})",
            "media_urls": [PHOTO, COVER],
            "videos": [{"post_url": CANONICAL, "video_url": VIDEO}],
        }
        uploaded: list[list[str]] = []
        calls: list[tuple[str, str]] = []

        def store(image_urls, **_kwargs):
            uploaded.append(list(image_urls))
            return {"images": [{"url": u, "embedded_url": "https://immich.example/x.jpg"} for u in image_urls], "share_url": ""}

        created = clip_requests.create(kind="post", source=POST_URL)
        with patch.object(clip_pipeline.web_article, "store_note_media", side_effect=store):
            clip_pipeline.run_post(
                created["id"],
                POST_URL,
                settings=lambda: SETTINGS,
                chat=lambda _s, _u, step: "潤稿" if step == "polish" else "標題",
                collect_threads=lambda _url: self.fail("not Threads"),
                fetch_public_post=lambda _url: payload,
                transcribe_video=lambda post_url, video_url: calls.append((post_url, video_url)) or "影片逐字稿",
            )
        stored = clip_requests.get(created["id"])
        self.assertEqual(stored["status"], "completed")
        self.assertEqual(uploaded, [[PHOTO, COVER]])
        self.assertEqual(calls, [(CANONICAL, VIDEO)])
        self.assertIn(f"## Video Transcript\n\n{CANONICAL}\n\n影片逐字稿", stored["content"])
        self.assertIn(CANONICAL, stored["sources"])


class TranscribeInstagramVideoTests(unittest.TestCase):
    def test_direct_download_uses_instagram_referer(self) -> None:
        seen: dict = {}

        def direct(_url, destination, _max, **kwargs):
            seen.update(kwargs)
            with open(destination, "wb") as output:
                output.write(b"x")
            return destination

        with (
            patch.object(webui, "_download_post_video_direct", side_effect=direct),
            patch.object(webui.transcriber, "transcribe", return_value={"text": "hi"}),
            patch.object(webui, "_settings_transcribe_options", return_value={}),
        ):
            self.assertEqual(webui._transcribe_post_video(CANONICAL, VIDEO), "hi")
        self.assertEqual(seen["referer"], "https://www.instagram.com/")

    def test_expired_cdn_link_falls_back_to_yt_dlp(self) -> None:
        def page(url, destination, _max, _progress):
            with open(destination, "wb") as output:
                output.write(b"x")
            return {"downloaded_path": destination}

        with (
            patch.object(webui, "_download_post_video_direct", side_effect=RuntimeError("HTTP 403")),
            patch.object(webui, "_download_media_page", side_effect=page) as media_page,
            patch.object(webui, "_download_threads_embed") as embed,
            patch.object(webui.transcriber, "transcribe", return_value={"text": "yt"}),
            patch.object(webui, "_settings_transcribe_options", return_value={}),
        ):
            self.assertEqual(webui._transcribe_post_video(CANONICAL, VIDEO), "yt")
        self.assertEqual(media_page.call_args.args[0], CANONICAL)
        embed.assert_not_called()


if __name__ == "__main__":
    unittest.main()
