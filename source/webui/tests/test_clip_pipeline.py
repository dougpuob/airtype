"""Post clips fetch linked web pages and nest them after Original Content."""

from unittest.mock import patch
import tempfile
import unittest

from app import clip_pipeline
from app import clip_requests
from app.clip_pipeline import (
    extract_post_external_urls,
    format_external_content,
    polish_source_text,
)


POST_URL = "https://www.threads.com/@a/post/1"
LINKED_URL = "https://huggingface.co/baidu/Unlimited-OCR"


class ExtractPostExternalUrlsTests(unittest.TestCase):
    def test_keeps_caption_and_markdown_links_in_order(self) -> None:
        content = (
            f"專案位置 {LINKED_URL}\n"
            "見 [說明](https://blog.example.com/note)\n"
            f"![](https://cdn.example.com/a.jpg)\n"
            f"{POST_URL}"
        )
        self.assertEqual(
            extract_post_external_urls(content, skip=[POST_URL, "https://cdn.example.com/a.jpg"]),
            [LINKED_URL, "https://blog.example.com/note"],
        )

    def test_skips_images_known_sources_and_blocked_hosts(self) -> None:
        content = (
            "https://www.youtube.com/watch?v=abc\n"
            "https://www.threads.com/@b/post/2\n"
            "https://localhost/secret\n"
            "https://cdn.example.com/photo.png\n"
            "https://news.example.com/story\n"
        )
        self.assertEqual(
            extract_post_external_urls(
                content + "\n![](https://cdn.example.com/photo.png)",
                skip=[],
            ),
            ["https://news.example.com/story"],
        )

    def test_strips_trailing_punctuation(self) -> None:
        self.assertEqual(
            extract_post_external_urls(f"看這裡 {LINKED_URL}。"),
            [LINKED_URL],
        )


class ExternalContentFormatTests(unittest.TestCase):
    def test_nests_title_then_url_then_body(self) -> None:
        formatted = format_external_content(
            [
                {
                    "title": "Unlimited-OCR",
                    "url": LINKED_URL,
                    "body": "模型介紹",
                },
                {
                    "title": "另一篇文章標題",
                    "url": "https://blog.example.com/note",
                    "body": "另一篇正文",
                },
            ]
        )
        self.assertEqual(
            formatted,
            "## Unlimited-OCR\n\n"
            f"{LINKED_URL}\n\n"
            "模型介紹\n\n"
            "## 另一篇文章標題\n\n"
            "https://blog.example.com/note\n\n"
            "另一篇正文",
        )

    def test_polish_source_labels_post_and_pages(self) -> None:
        source = polish_source_text(
            "貼文正文",
            [{"title": "Unlimited-OCR", "url": LINKED_URL, "body": "模型介紹"}],
        )
        self.assertIn("原始貼文：\n貼文正文", source)
        self.assertIn("標題：Unlimited-OCR", source)
        self.assertIn(f"位置：{LINKED_URL}", source)
        self.assertIn("模型介紹", source)


class PostExternalDraftTests(unittest.TestCase):
    def test_post_note_has_external_section_article_does_not(self) -> None:
        post = clip_pipeline.build_draft(
            kind="post",
            title="Hello",
            content="貼文",
            polished="潤稿",
            ai_tags="",
            sources=[POST_URL],
            guid="guid",
            share_url="",
            external_content=format_external_content(
                [{"title": "Unlimited-OCR", "url": LINKED_URL, "body": "模型介紹"}]
            ),
        )
        note = post["note"]
        self.assertIn("# Original Content\n\n貼文\n", note)
        self.assertIn("# Original External Content\n\n## Unlimited-OCR\n\n", note)
        self.assertIn(f"{LINKED_URL}\n\n模型介紹\n", note)
        self.assertLess(note.index("# Original Content"), note.index("# Original External Content"))
        self.assertLess(note.index("# Original External Content"), note.index("\nEND"))
        self.assertNotIn("huggingface", post["tags"])

        article = clip_pipeline.build_draft(
            kind="article",
            title="Hello",
            content="正文",
            polished="潤稿",
            ai_tags="",
            sources=["https://example.com/page"],
            guid="guid",
            share_url="",
            external_content="should not appear",
        )
        self.assertNotIn("# Original External Content", article["note"])
        self.assertEqual(article["external_content"], "")


class RunPostExternalPagesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        clip_requests.configure(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_fetches_linked_pages_and_sends_both_to_polish(self) -> None:
        created = clip_requests.create(kind="post", source=POST_URL)
        chats: list[tuple[str, str]] = []

        def chat(_system: str, user: str, step: str) -> str:
            chats.append((step, user))
            if step == "polish":
                return "合併後的潤稿"
            if step == "title":
                return "標題"
            return "#OCR"

        def collect(_url: str) -> dict:
            return {
                "markdown": f"專案位置 {LINKED_URL}\n\n![](https://cdn.example.com/a.jpg)",
                "posts": [{"url": POST_URL, "media_urls": []}],
                "guid": "guid",
                "author": "author",
            }

        with patch.object(
            clip_pipeline.web_article,
            "fetch_markdown",
            return_value="# Unlimited-OCR\n\n模型介紹\n",
        ) as fetch:
            clip_pipeline.run_post(
                created["id"],
                POST_URL,
                settings=lambda: {"web_to_markdown": {}, "immich": {}, "capture_post": {"ai_title_enabled": False}},
                chat=chat,
                collect_threads=collect,
                fetch_public_post=lambda _url: {},
            )
            fetch.assert_called_once_with(LINKED_URL, timeout_seconds=60)

        stored = clip_requests.get(created["id"])
        assert stored is not None
        polish_user = next(user for step, user in chats if step == "polish")
        self.assertIn("原始貼文：", polish_user)
        self.assertIn(LINKED_URL, polish_user)
        self.assertIn("模型介紹", polish_user)
        self.assertIn("## Unlimited-OCR\n\n" + LINKED_URL + "\n\n模型介紹", stored["note"])
        self.assertIn("# Original External Content", stored["note"])
        self.assertNotIn("huggingface", stored["tags"])
        self.assertEqual(stored["content"], f"專案位置 {LINKED_URL}\n\n![](https://cdn.example.com/a.jpg)")

    def test_failed_fetch_still_completes_the_clip(self) -> None:
        created = clip_requests.create(kind="post", source=POST_URL)

        def chat(_system: str, user: str, step: str) -> str:
            return "潤稿" if step == "polish" else "標題"

        with patch.object(clip_pipeline.web_article, "fetch_markdown", side_effect=RuntimeError("blocked")):
            clip_pipeline.run_post(
                created["id"],
                POST_URL,
                settings=lambda: {"web_to_markdown": {}, "immich": {}, "capture_post": {"ai_title_enabled": False}},
                chat=chat,
                collect_threads=lambda _url: {
                    "markdown": f"專案位置 {LINKED_URL}",
                    "posts": [{"url": POST_URL}],
                    "guid": "guid",
                    "author": "author",
                },
                fetch_public_post=lambda _url: {},
            )

        stored = clip_requests.get(created["id"])
        assert stored is not None
        self.assertEqual(stored["status"], "completed")
        self.assertIn("# Original External Content\n\n---", stored["note"])
        self.assertEqual(stored["external_content"], "")


if __name__ == "__main__":
    unittest.main()
