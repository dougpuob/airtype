"""Threads post videos are Whisper-transcribed into the same capture-post note."""

from unittest.mock import patch
import os
import tempfile
import unittest

from app import clip_pipeline
from app import clip_requests
from app import main as webui


POST_URL = "https://www.threads.com/@a/post/ABC"
REPLY_URL = "https://www.threads.com/@a/post/DEF"
IMAGE_URL = "https://scontent.cdninstagram.com/v/t51/photo.jpg?stp=1"
VIDEO_URL = "https://scontent.cdninstagram.com/o1/v/t2/f2/m86/clip.mp4?efg=1"
VIDEO_URL_2 = "https://scontent.cdninstagram.com/o1/v/t2/f2/m86/second.mp4?efg=2"
SETTINGS = {"web_to_markdown": {}, "immich": {}, "capture_post": {"ai_title_enabled": False}}


def _chat(_system: str, _user: str, step: str) -> str:
    return "潤稿" if step == "polish" else "標題"


def _chain(posts: list[dict]) -> dict:
    return {
        "markdown": "\n\n".join(
            "\n\n".join([p["text"], *[f"![]({u})" for u in p.get("media_urls", [])]]) for p in posts
        ),
        "posts": posts,
        "guid": "guid",
        "author": "a",
    }


class PostVideosTests(unittest.TestCase):
    def test_finds_videos_with_their_post_and_skips_images(self) -> None:
        posts = [
            {"url": POST_URL, "media_urls": [IMAGE_URL, VIDEO_URL]},
            {"url": REPLY_URL, "media_urls": [VIDEO_URL_2, VIDEO_URL]},
            "not a post",
        ]
        self.assertEqual(
            clip_pipeline.post_videos(posts),
            [
                {"post_url": POST_URL, "video_url": VIDEO_URL},
                {"post_url": REPLY_URL, "video_url": VIDEO_URL_2},
            ],
        )

    def test_no_video(self) -> None:
        self.assertEqual(clip_pipeline.post_videos([{"url": POST_URL, "media_urls": [IMAGE_URL]}]), [])


class RunPostVideoTranscriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        clip_requests.configure(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _run(self, posts: list[dict], transcribe, polish_inputs: list[str] | None = None) -> dict:
        created = clip_requests.create(kind="post", source=POST_URL)

        def chat(system: str, user: str, step: str) -> str:
            if step == "polish" and polish_inputs is not None:
                polish_inputs.append(user)
            return _chat(system, user, step)

        uploaded: list[list[str]] = []

        def store(image_urls, **_kwargs):
            uploaded.append(list(image_urls))
            return {"images": [{"url": u, "embedded_url": "https://immich.example/x.jpg"} for u in image_urls], "share_url": ""}

        with patch.object(clip_pipeline.web_article, "store_note_media", side_effect=store):
            clip_pipeline.run_post(
                created["id"],
                POST_URL,
                settings=lambda: SETTINGS,
                chat=chat,
                collect_threads=lambda _url: _chain(posts),
                fetch_public_post=lambda _url: {},
                transcribe_video=transcribe,
            )
        stored = clip_requests.get(created["id"])
        assert stored is not None
        stored["_uploaded"] = uploaded
        return stored

    def test_transcript_is_added_to_the_post_note(self) -> None:
        calls: list[tuple[str, str]] = []
        polish_inputs: list[str] = []

        def transcribe(post_url: str, video_url: str) -> str:
            calls.append((post_url, video_url))
            return "大家好，這是影片內容。"

        stored = self._run(
            [{"url": POST_URL, "text": "貼文本文", "media_urls": [IMAGE_URL, VIDEO_URL]}],
            transcribe,
            polish_inputs,
        )
        self.assertEqual(stored["status"], "completed")
        self.assertEqual(calls, [(POST_URL, VIDEO_URL)])
        # Images still go to Immich; the video is not uploaded as a photo.
        self.assertEqual(stored["_uploaded"], [[IMAGE_URL]])
        self.assertIn("貼文本文", stored["content"])
        self.assertIn("https://immich.example/x.jpg", stored["content"])
        self.assertIn(f"## Video Transcript\n\n{POST_URL}\n\n大家好，這是影片內容。", stored["content"])
        self.assertTrue(stored["content"].index("貼文本文") < stored["content"].index("## Video Transcript"))
        self.assertIn("## Video Transcript", stored["note"])
        self.assertIn("大家好，這是影片內容。", stored["note"])
        self.assertIn("大家好，這是影片內容。", polish_inputs[0])

    def test_multiple_videos_get_numbered_sections(self) -> None:
        stored = self._run(
            [
                {"url": POST_URL, "text": "一", "media_urls": [VIDEO_URL]},
                {"url": REPLY_URL, "text": "二", "media_urls": [VIDEO_URL_2]},
            ],
            lambda post_url, _video: f"逐字稿 {post_url[-3:]}",
        )
        self.assertIn(f"### Video 1\n\n{POST_URL}\n\n逐字稿 ABC", stored["content"])
        self.assertIn(f"### Video 2\n\n{REPLY_URL}\n\n逐字稿 DEF", stored["content"])

    def test_failed_video_keeps_the_post_and_says_why(self) -> None:
        def transcribe(_post_url: str, _video_url: str) -> str:
            raise RuntimeError("Could not download the video (the post may be private or login-only): HTTP 403")

        stored = self._run([{"url": POST_URL, "text": "貼文本文", "media_urls": [VIDEO_URL]}], transcribe)
        self.assertEqual(stored["status"], "completed")
        self.assertIn("貼文本文", stored["content"])
        self.assertIn("_(Video transcript unavailable: Could not download the video", stored["content"])
        self.assertIn("login-only", stored["note"])

    def test_caps_video_count(self) -> None:
        videos = [f"https://cdn.example.com/v{i}.mp4" for i in range(clip_pipeline.MAX_POST_VIDEOS + 2)]
        calls: list[str] = []
        stored = self._run(
            [{"url": POST_URL, "text": "t", "media_urls": videos}],
            lambda _p, video: calls.append(video) or "ok",
        )
        self.assertEqual(len(calls), clip_pipeline.MAX_POST_VIDEOS)
        self.assertIn("2 more video(s)", stored["content"])

    def test_post_without_video_is_unchanged(self) -> None:
        stored = self._run(
            [{"url": POST_URL, "text": "貼文本文", "media_urls": []}],
            lambda *_args: self.fail("should not transcribe"),
        )
        self.assertNotIn("Video Transcript", stored["note"])


class TranscribePostVideoTests(unittest.TestCase):
    def test_direct_download_then_whisper(self) -> None:
        def direct(_url, destination, _max, **_kwargs):
            with open(destination, "wb") as output:
                output.write(b"x")
            return destination

        with (
            patch.object(webui, "_download_post_video_direct", side_effect=direct),
            patch.object(webui, "_download_threads_embed") as embed,
            patch.object(webui.transcriber, "transcribe", return_value={"text": " 你好 "}) as whisper,
            patch.object(webui, "_settings_transcribe_options", return_value={"language": "zh-tw"}),
        ):
            self.assertEqual(webui._transcribe_post_video(POST_URL, VIDEO_URL), "你好")
        embed.assert_not_called()
        self.assertEqual(whisper.call_args.kwargs["language"], "zh-tw")

    def test_falls_back_to_embed_downloader(self) -> None:
        seen: dict[str, str] = {}

        def embed(url, destination, _max, _progress):
            seen["url"] = url
            with open(destination, "wb") as output:
                output.write(b"x")
            return {"downloaded_path": destination}

        def whisper(source_path, **_options):
            seen["exists"] = str(os.path.exists(source_path))
            return {"text": "embed 逐字稿"}

        with (
            patch.object(webui, "_download_post_video_direct", side_effect=RuntimeError("HTTP 403")),
            patch.object(webui, "_download_threads_embed", side_effect=embed),
            patch.object(webui.transcriber, "transcribe", side_effect=whisper),
            patch.object(webui, "_settings_transcribe_options", return_value={}),
        ):
            self.assertEqual(webui._transcribe_post_video(POST_URL, VIDEO_URL), "embed 逐字稿")
        self.assertEqual(seen, {"url": POST_URL, "exists": "True"})

    def test_both_downloads_fail_with_clear_message(self) -> None:
        with (
            patch.object(webui, "_download_post_video_direct", side_effect=RuntimeError("HTTP 403")),
            patch.object(webui, "_download_threads_embed", side_effect=RuntimeError("no public MP4")),
            patch.object(webui.transcriber, "transcribe") as whisper,
        ):
            with self.assertRaisesRegex(RuntimeError, "private or login-only"):
                webui._transcribe_post_video(POST_URL, VIDEO_URL)
        whisper.assert_not_called()


if __name__ == "__main__":
    unittest.main()
