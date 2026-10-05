"""Tests for the web-article pipeline."""

import unittest
import uuid
from unittest.mock import patch

from app import web_article
from app.web_article import KnownSourceError


class _FakeResponse:
    def __init__(self, status_code: int = 200, text: str = "") -> None:
        self.status_code = status_code
        self.text = text


class _FakeImmich:
    last = None

    def __init__(self, server_url, api_key, timeout_seconds=60):
        self.server_url = server_url
        self.api_key = api_key
        self.configured = bool(server_url and api_key)
        self.uploaded = []
        self.tagged = None
        self.tag_name = None
        _FakeImmich.last = self

    def upload_asset(self, *, data, filename, content_type, device_asset_id, file_created_at, device_id="airtype"):
        asset_id = f"a{len(self.uploaded)}"
        self.uploaded.append(
            {"filename": filename, "device_asset_id": device_asset_id, "size": len(data)}
        )
        return {"id": asset_id, "status": "created", "duplicate": False}

    def ensure_tag(self, name):
        self.tag_name = name
        return "tag-1"

    def tag_assets(self, tag_id, asset_ids):
        self.tagged = (tag_id, list(asset_ids))

    def create_shared_link(self, asset_ids, *, allow_download=False, description=""):
        return {"key": "K", "share_url": "https://immich.example/share/K"}

    def asset_thumbnail_url(self, asset_id, share_key, size="preview"):
        return f"https://immich.example/api/assets/{asset_id}/thumbnail?key={share_key}&size={size}"

    def create_album(self, album_name, asset_ids):
        return "album-1"


class _SyncExecutor:
    def submit(self, fn, *args, **kwargs):
        fn(*args, **kwargs)


ARTICLE_MARKDOWN = """# 測試文章

這是第一段內文，描述這篇文章的主題、背景與動機，用來確認內文字數統計可以超過短文警告的門檻值。

![第一張](https://cdn.example.com/a.png)

![第二張](https://cdn.example.com/b.jpg "標題")

這是第二段內文，補充更多細節、例子與結論；圖片連結會被重寫成 Immich 的縮圖網址，原始網址則不應該再出現在筆記中。

- 重點一：後端會把圖片上傳到 Immich 並掛上這篇筆記的 GUID 標籤
- 重點二：下載或上傳失敗的圖片會保留原始連結並記錄警告
"""


def _run_article_job(
    patch_targets: dict,
    url: str = "https://example.com/article",
    markdown: str = ARTICLE_MARKDOWN,
) -> dict:
    with (
        patch.object(web_article, "_get_executor", return_value=_SyncExecutor()),
        patch.object(web_article, "fetch_markdown", return_value=markdown),
        patch.object(web_article, "download_image", **patch_targets["download"]),
        patch.object(web_article, "ImmichClient", patch_targets["immich"]),
    ):
        payload = web_article.start_job(
            url,
            web_to_markdown_api_key="mk_key",
            timeout_seconds=30,
            download_max_mb=5,
            immich_server_url="https://immich.example",
            immich_api_key="immich-key",
            create_album=False,
        )
    return payload


class ExtractAndRewriteTests(unittest.TestCase):
    def test_extract_image_urls_from_markdown_and_html(self) -> None:
        markdown = (
            '![a](https://a.site/1.png)\n'
            '![b](<https://a.site/2.jpg> "title")\n'
            '<img src="https://a.site/3.webp">\n'
            "![dup](https://a.site/1.png)\n"
        )
        self.assertEqual(
            web_article.extract_image_urls(markdown),
            ["https://a.site/1.png", "https://a.site/2.jpg", "https://a.site/3.webp"],
        )

    def test_extract_image_urls_skips_data_and_resolves_relative(self) -> None:
        markdown = "![d](data:image/png;base64,AAAA)\n![r](/img/rel.png)\n![o](ftp://x/y.png)\n"
        self.assertEqual(web_article.extract_image_urls(markdown), [])
        self.assertEqual(
            web_article.extract_image_urls(markdown, base_url="https://site.example/post/1"),
            ["https://site.example/img/rel.png"],
        )

    def test_rewrite_image_links(self) -> None:
        rewritten = web_article.rewrite_image_links(
            "![a](https://old/x.png)", {"https://old/x.png": "https://new/x.png"}
        )
        self.assertEqual(rewritten, "![a](https://new/x.png)")

    def test_extract_title(self) -> None:
        self.assertEqual(web_article.extract_title(ARTICLE_MARKDOWN), "測試文章")
        self.assertEqual(web_article.extract_title("沒有標題", "備用"), "備用")

    def test_blocked_host_reason(self) -> None:
        for url in (
            "https://localhost/x",
            "https://md.genedai.me/https://example.com",
            "http://127.0.0.1:8000/x",
            "http://192.168.1.10/x",
            "http://10.0.0.5/x",
            "http://[::1]/x",
        ):
            self.assertTrue(web_article.blocked_host_reason(url), url)
        self.assertEqual(web_article.blocked_host_reason("https://blog.example.com/"), "")

    def test_image_filename(self) -> None:
        self.assertEqual(web_article.image_filename(0, "image/png"), "image-0.png")
        self.assertEqual(web_article.image_filename(1, "image/jpeg"), "image-1.jpg")

    def test_article_body_chars_ignores_headings_and_rules(self) -> None:
        markdown = "# 標題\n\n---\n\n這是內文，超過一些字。\n\n## 子標題\n"
        self.assertEqual(web_article.article_body_chars(markdown), len("這是內文，超過一些字。"))


class StartJobValidationTests(unittest.TestCase):
    def test_known_source_rejected_with_hint(self) -> None:
        with self.assertRaises(KnownSourceError) as ctx:
            web_article.start_job("https://www.threads.com/@a/post/1")
        self.assertIn("Capture Post", str(ctx.exception))

    def test_blocked_host_rejected(self) -> None:
        with self.assertRaises(ValueError):
            web_article.start_job("https://localhost/article")

    def test_invalid_url_rejected(self) -> None:
        with self.assertRaises(ValueError):
            web_article.start_job("not a url")


class FetchMarkdownTests(unittest.TestCase):
    def test_raw_true_and_bearer_header(self) -> None:
        captured: dict = {}

        def fake_get(url, headers=None, timeout=None, allow_redirects=False):
            captured["url"] = url
            captured["headers"] = headers
            return _FakeResponse(200, "# hi")

        with patch("curl_cffi.requests.get", side_effect=fake_get):
            web_article.fetch_markdown("https://example.com/p?q=1", api_key="mk_x")
            self.assertEqual(captured["url"], "https://md.genedai.me/https://example.com/p?q=1&raw=true")
            self.assertEqual(captured["headers"]["Authorization"], "Bearer mk_x")
            self.assertEqual(captured["headers"]["Accept"], "text/markdown")
        with patch("curl_cffi.requests.get", side_effect=fake_get):
            web_article.fetch_markdown("https://example.com/plain")
            self.assertEqual(captured["url"], "https://md.genedai.me/https://example.com/plain?raw=true")
        with patch("curl_cffi.requests.get", side_effect=fake_get):
            web_article.fetch_markdown("https://example.com/page#section")
            self.assertEqual(captured["url"], "https://md.genedai.me/https://example.com/page?raw=true")

    def test_http_error_becomes_runtime_error(self) -> None:
        with patch("curl_cffi.requests.get", return_value=_FakeResponse(402, "quota")):
            with self.assertRaises(RuntimeError):
                web_article.fetch_markdown("https://example.com/x")

    def test_html_response_rejected(self) -> None:
        with patch(
            "curl_cffi.requests.get",
            return_value=_FakeResponse(200, "<!DOCTYPE html><html><body>reading view</body></html>"),
        ):
            with self.assertRaises(RuntimeError) as ctx:
                web_article.fetch_markdown("https://example.com/x")
        self.assertIn("HTML", str(ctx.exception))


class RunJobTests(unittest.TestCase):
    def test_success_uploads_tags_shares_and_rewrites(self) -> None:
        payload = _run_article_job(
            {
                "download": {"side_effect": [(b"png-bytes", "image/png"), (b"jpg-bytes", "image/jpeg")]},
                "immich": _FakeImmich,
            }
        )
        self.assertEqual(payload["status"], "completed")
        self.assertEqual(payload["progress"], 100)
        uuid.UUID(payload["guid"])
        self.assertEqual(payload["title"], "測試文章")
        self.assertEqual(payload["share_url"], "https://immich.example/share/K")
        self.assertEqual([item["status"] for item in payload["images"]], ["uploaded", "uploaded"])
        self.assertEqual([item["asset_id"] for item in payload["images"]], ["a0", "a1"])
        self.assertEqual(payload["warnings"], [])
        self.assertEqual(_FakeImmich.last.tag_name, payload["guid"])
        self.assertEqual(_FakeImmich.last.tagged, ("tag-1", ["a0", "a1"]))
        self.assertNotIn("cdn.example.com", payload["markdown"])
        self.assertIn(
            "![第一張](https://immich.example/api/assets/a0/thumbnail?key=K&size=preview)",
            payload["markdown"],
        )
        self.assertIn(
            '![第二張](https://immich.example/api/assets/a1/thumbnail?key=K&size=preview "標題")',
            payload["markdown"],
        )

    def test_duplicate_asset_rewrites_to_existing_immich_url(self) -> None:
        class _DuplicateImmich(_FakeImmich):
            def upload_asset(self, *, data, filename, content_type, device_asset_id, file_created_at, device_id="airtype"):
                self.uploaded.append({"filename": filename, "size": len(data)})
                return {"id": "existing-asset", "status": "duplicate", "duplicate": True}

        payload = _run_article_job(
            {
                "download": {"return_value": (b"png-bytes", "image/png")},
                "immich": _DuplicateImmich,
            }
        )
        self.assertEqual(payload["status"], "completed")
        self.assertEqual(payload["images"][0]["asset_id"], "existing-asset")
        self.assertTrue(payload["images"][0]["duplicate"])
        self.assertEqual(payload["warnings"], [])
        self.assertEqual(_FakeImmich.last.tag_name, payload["guid"])
        self.assertEqual(_FakeImmich.last.tagged, ("tag-1", ["existing-asset", "existing-asset"]))
        self.assertNotIn("cdn.example.com", payload["markdown"])
        self.assertIn(
            "https://immich.example/api/assets/existing-asset/thumbnail?key=K&size=preview",
            payload["markdown"],
        )

    def test_image_download_failure_keeps_original_link(self) -> None:
        def fake_download(url, *, article_url="", timeout_seconds=60, max_bytes=0):
            if url.endswith("b.jpg"):
                raise RuntimeError("下載失敗")
            return b"png-bytes", "image/png"

        payload = _run_article_job(
            {
                "download": {"side_effect": fake_download},
                "immich": _FakeImmich,
            }
        )
        self.assertEqual(payload["status"], "completed")
        statuses = [item["status"] for item in payload["images"]]
        self.assertEqual(statuses, ["uploaded", "remote"])
        self.assertEqual(payload["warnings"][-1].startswith("圖片上傳失敗"), True)
        self.assertIn("https://cdn.example.com/b.jpg", payload["markdown"])
        self.assertIn("api/assets/a0/thumbnail", payload["markdown"])

    def test_without_immich_keeps_all_original_links(self) -> None:
        payload = _run_article_job_unconfigured()
        self.assertEqual(payload["status"], "completed")
        self.assertTrue(any("尚未設定 Immich" in warning for warning in payload["warnings"]))
        self.assertNotIn("immich.example", payload["markdown"])
        self.assertIn("https://cdn.example.com/a.png", payload["markdown"])

    def test_short_body_gets_warning(self) -> None:
        payload = _run_article_job(
            {
                "download": {"side_effect": AssertionError("should not download")},
                "immich": _FakeImmich,
            },
            markdown="# 只有標題\n",
        )
        self.assertEqual(payload["status"], "completed")
        self.assertEqual(payload["title"], "只有標題")
        self.assertTrue(any("極少的內文" in warning for warning in payload["warnings"]))


def _run_article_job_unconfigured() -> dict:
    with (
        patch.object(web_article, "_get_executor", return_value=_SyncExecutor()),
        patch.object(web_article, "fetch_markdown", return_value=ARTICLE_MARKDOWN),
        patch.object(web_article, "download_image", side_effect=AssertionError("should not download")),
        patch.object(web_article, "ImmichClient", _FakeImmich),
    ):
        return web_article.start_job(
            "https://example.com/article",
            web_to_markdown_api_key="",
            timeout_seconds=30,
            download_max_mb=5,
            immich_server_url="",
            immich_api_key="",
            create_album=False,
        )


if __name__ == "__main__":
    unittest.main()