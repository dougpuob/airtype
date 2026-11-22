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


SAMPLE_ARTICLE_HTML = """<!DOCTYPE html>
<html lang="zh-Hant">
<head>
  <meta charset="utf-8">
  <title>測試文章</title>
  <meta property="og:title" content="測試文章">
</head>
<body>
  <header><nav>選單不該出現在內文</nav></header>
  <article>
    <h1>測試文章</h1>
    <p>這是第一段內文，描述這篇文章的主題、背景與動機，用來確認 Trafilatura 可以抽出主文。</p>
    <p><img src="https://cdn.example.com/a.png" alt="第一張"></p>
    <p>這是第二段內文，補充更多細節、例子與結論。</p>
  </article>
  <footer>版權宣告不該出現在內文</footer>
</body>
</html>
"""


class FetchMarkdownTests(unittest.TestCase):
    def test_html_to_markdown_extracts_title_body_and_image(self) -> None:
        markdown = web_article.html_to_markdown(
            SAMPLE_ARTICLE_HTML, url="https://example.com/article"
        )
        self.assertIn("測試文章", markdown)
        self.assertIn("第一段內文", markdown)
        self.assertIn("https://cdn.example.com/a.png", markdown)
        self.assertNotIn("選單不該出現在內文", markdown)

    def test_html_to_markdown_empty_body_raises(self) -> None:
        with self.assertRaises(RuntimeError) as ctx:
            web_article.html_to_markdown("<html><body></body></html>")
        self.assertIn("Could not extract an article", str(ctx.exception))

    def test_fetch_markdown_requests_article_url(self) -> None:
        captured: dict = {}

        def fake_get(url, headers=None, timeout=None, allow_redirects=False, impersonate=None):
            captured["url"] = url
            captured["headers"] = headers
            captured["impersonate"] = impersonate
            return _FakeResponse(200, SAMPLE_ARTICLE_HTML)

        with patch("curl_cffi.requests.get", side_effect=fake_get):
            markdown = web_article.fetch_markdown("https://example.com/p?q=1#section")
        self.assertEqual(captured["url"], "https://example.com/p?q=1")
        self.assertEqual(captured["impersonate"], "chrome131")
        self.assertIn("text/html", captured["headers"]["Accept"])
        self.assertNotIn("Authorization", captured["headers"])
        self.assertIn("第一段內文", markdown)

    def test_csdn_uses_a_plain_request(self) -> None:
        self.assertEqual(web_article.html_fetch_strategy("https://blog.csdn.net/a/article/details/1"), "plain")
        self.assertEqual(web_article.html_fetch_strategy("https://csdn.net/x"), "plain")
        self.assertEqual(web_article.html_fetch_strategy("https://www.csdn.net/x"), "plain")
        self.assertEqual(web_article.html_fetch_strategy("https://notcsdn.net/x"), "chrome")
        self.assertEqual(web_article.html_fetch_strategy("https://example.com/p"), "chrome")

        captured: dict = {}

        class _FakeClient:
            @staticmethod
            def get(url, headers=None, timeout=None, allow_redirects=False, **kwargs):
                captured["url"] = url
                captured["kwargs"] = kwargs
                return _FakeResponse(200, "<html><body>ok</body></html>")

        with patch.object(web_article, "_curl_requests", return_value=_FakeClient):
            web_article.fetch_html("https://blog.csdn.net/DAzhutizi_a/article/details/126618986#top")
            self.assertNotIn("impersonate", captured["kwargs"])
            self.assertEqual(captured["url"], "https://blog.csdn.net/DAzhutizi_a/article/details/126618986")
            web_article.fetch_html("https://example.com/p")
            self.assertEqual(captured["kwargs"].get("impersonate"), "chrome131")

    def test_http_error_becomes_runtime_error(self) -> None:
        with patch("curl_cffi.requests.get", return_value=_FakeResponse(403, "forbidden")):
            with self.assertRaises(RuntimeError) as ctx:
                web_article.fetch_markdown("https://example.com/x")
        self.assertIn("403", str(ctx.exception))

    def test_empty_extraction_becomes_runtime_error(self) -> None:
        with patch(
            "curl_cffi.requests.get",
            return_value=_FakeResponse(200, "<!DOCTYPE html><html><body></body></html>"),
        ):
            with self.assertRaises(RuntimeError) as ctx:
                web_article.fetch_markdown("https://example.com/x")
        self.assertIn("Could not extract an article", str(ctx.exception))


JOB_104_PAYLOAD = {
    "data": {
        "header": {
            "jobName": "AI軟體研發工程師",
            "custName": "測試科技股份有限公司",
            "appearDate": "2026/10/28",
        },
        "jobDetail": {
            "jobDescription": "工作內容\n* 開發 AI 自主系統\n* 建立目標辨識模型",
            "jobCategory": [{"description": "軟體工程師"}, {"description": "AI工程師"}],
            "salary": "待遇面議",
            "addressRegion": "台北市中山區",
            "addressDetail": "松江路111號",
            "needEmp": "1人",
        },
        "condition": {
            "workExp": "2年以上",
            "edu": "大學",
            "major": ["電機電子工程相關"],
            "language": [
                {"language": "英文", "ability": {"listening": "精通", "speaking": "中等"}}
            ],
            "specialty": [{"description": "Python"}, {"description": "PyTorch"}],
            "other": "熟悉 Linux 開發環境",
        },
        "welfare": {"tag": [], "welfare": "◆ 獎金/禮品類\n\t1.年終獎金"},
    }
}

JS_SHELL_HTML = """<!DOCTYPE html><html><head><title>工作頁－104人力銀行</title></head>
<body><noscript><strong>We're sorry but vue-start doesn't work properly without JavaScript enabled. Please enable it to continue.</strong></noscript>
<div id="app"></div></body></html>"""


class _FakeUrlopenResponse:
    def __init__(self, body: bytes, status: int = 200) -> None:
        self._body = body
        self.status = status

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class Job104Tests(unittest.TestCase):
    def test_job_id_parsing(self) -> None:
        self.assertEqual(
            web_article.job_104_id(
                "https://www.104.com.tw/job/92ppf?jobsource=vipshare&utm_source=vip"
            ),
            "92ppf",
        )
        self.assertEqual(web_article.job_104_id("https://m.104.com.tw/job/abc12"), "abc12")
        self.assertEqual(web_article.job_104_id("https://www.104.com.tw/company/awt21ew"), "")
        self.assertEqual(web_article.job_104_id("https://example.com/job/92ppf"), "")

    def test_payload_renders_markdown(self) -> None:
        markdown = web_article.job_104_markdown(JOB_104_PAYLOAD, job_id="92ppf")
        self.assertTrue(markdown.startswith("# AI軟體研發工程師 – 測試科技股份有限公司\n"))
        self.assertIn("- 工作待遇：待遇面議", markdown)
        self.assertIn("- 上班地點：台北市中山區松江路111號", markdown)
        self.assertIn("- 職務類別：軟體工程師、AI工程師", markdown)
        self.assertIn("## 工作內容", markdown)
        self.assertIn("建立目標辨識模型", markdown)
        self.assertIn("- 語文條件：英文（聽精通、說中等）", markdown)
        self.assertIn("- 擅長工具：Python、PyTorch", markdown)
        self.assertIn("熟悉 Linux 開發環境", markdown)
        self.assertIn("## 福利制度", markdown)
        self.assertIn("年終獎金", markdown)
        self.assertEqual(web_article.extract_title(markdown), "AI軟體研發工程師 – 測試科技股份有限公司")
        self.assertGreater(web_article.article_body_chars(markdown), 50)

    def test_payload_without_data_raises(self) -> None:
        with self.assertRaises(RuntimeError):
            web_article.job_104_markdown({"data": {}})

    def test_fetch_markdown_uses_104_api_not_html(self) -> None:
        import json

        captured: dict = {}

        def fake_urlopen(request, timeout=None):
            captured["url"] = request.full_url
            captured["headers"] = {k.lower(): v for k, v in request.header_items()}
            return _FakeUrlopenResponse(json.dumps(JOB_104_PAYLOAD).encode("utf-8"))

        with patch("urllib.request.urlopen", side_effect=fake_urlopen), patch(
            "curl_cffi.requests.get", side_effect=AssertionError("HTML fetch must not run")
        ):
            markdown = web_article.fetch_markdown(
                "https://www.104.com.tw/job/92ppf?jobsource=vipshare"
            )
        self.assertEqual(captured["url"], "https://www.104.com.tw/api/jobs/92ppf")
        self.assertEqual(captured["headers"]["accept"], "application/json")
        self.assertEqual(captured["headers"]["referer"], "https://www.104.com.tw/job/92ppf")
        self.assertIn("Chrome/", captured["headers"]["user-agent"])
        self.assertIn("## 工作內容", markdown)

    def test_104_http_error_is_clear(self) -> None:
        import urllib.error

        error = urllib.error.HTTPError(
            "https://www.104.com.tw/api/jobs/zzz", 404, "Not Found", {}, None
        )
        with patch("urllib.request.urlopen", side_effect=error):
            with self.assertRaises(RuntimeError) as ctx:
                web_article.fetch_markdown("https://www.104.com.tw/job/zzz")
        self.assertIn("104 job API returned 404", str(ctx.exception))


SALE_591_PAYLOAD = {
    "status": 1,
    "data": {
        "title": "景觀三房車位",
        "price": "1,428萬元",
        "unitprice": "31.27萬/坪",
        "region": "桃園市",
        "section": "八德區",
        "street": "建德路",
        "addr_number": "x",
        "edit_addr_number": "40",
        "hide_addr_detail": "1",
        "casesname": "麗寶豐洲",
        "layout": "3房2廳2衛2陽臺",
        "floor": "11F/13F",
        "age": "7年",
        "shape": "電梯大樓",
        "fitment": "簡易裝潢",
        "managefee": "2350元/月",
        "parking_new": "12.04坪，平面式，已含售金內",
        "purpose": "住家用",
        "ratioRate": "31%",
        "linkman": "張小姐",
        "identity": "仲介",
        "company_name": "測試不動產",
        "sub_company_name": "測試加盟店",
        "econ_name": "測試經紀業",
        "mobile": "0900-000-000",
        "email": "agent@example.com",
        "remark": "高樓層景觀，座北朝南。",
        "info": [
            {"name": "樓層", "value": "11F/13F"},
            {"name": "屋齡", "value": "7年"},
            {"name": "空值", "value": ""},
        ],
        "area_intro_arr": [
            {"name": "登記總面積", "value": "45.67坪"},
            {"name": "土地坪數", "value": "-"},
        ],
        "photoinfo": [
            {"type": "4", "photo": "https://img.example/house/a.jpeg!1000x.water2.jpeg"},
            {"type": "3", "photo": "https://img.example/house/plan.jpeg!1000x.water2.jpeg"},
            {"type": "1", "photo": "", "video": "https://video.example/tour.mp4"},
            {"type": "4", "photo": "https://img.example/house/a.jpeg!1000x.water2.jpeg"},
        ],
    },
}


class Sale591Tests(unittest.TestCase):
    def test_sale_id_parsing(self) -> None:
        self.assertEqual(
            web_article.sale_591_id(
                "https://sale.591.com.tw/home/house/detail/2/21222842.html?from=list"
            ),
            "21222842",
        )
        self.assertEqual(
            web_article.sale_591_id("https://sale.591.com.tw/home/house/detail/2/21222842"),
            "21222842",
        )
        self.assertEqual(
            web_article.sale_591_id("https://www.591.com.tw/home/house/detail/2/99.html#photos"),
            "99",
        )
        self.assertEqual(web_article.sale_591_id("https://rent.591.com.tw/21222842"), "")
        self.assertEqual(
            web_article.sale_591_id("https://sale.591.com.tw/home/house/detail/1/21222842.html"),
            "",
        )
        self.assertEqual(web_article.sale_591_id("https://not591.com.tw/home/house/detail/2/1.html"), "")

    def test_payload_renders_markdown(self) -> None:
        markdown = web_article.sale_591_markdown(SALE_591_PAYLOAD, house_id="21222842")
        self.assertTrue(markdown.startswith("# 景觀三房車位\n"))
        self.assertIn("- 售價：1,428萬元", markdown)
        self.assertIn("- 單價：31.27萬/坪", markdown)
        self.assertIn("- 地區：桃園市八德區建德路", markdown)
        self.assertNotIn("40", markdown)
        self.assertIn("- 社區：麗寶豐洲", markdown)
        self.assertIn("- 格局：3房2廳2衛2陽臺", markdown)
        self.assertIn("- 樓層：11F/13F", markdown)
        self.assertIn("- 屋齡：7年", markdown)
        self.assertIn("- 車位：12.04坪，平面式，已含售金內", markdown)
        self.assertIn("- 仲介：張小姐（仲介）", markdown)
        self.assertIn("- 公司：測試不動產 測試加盟店", markdown)
        self.assertIn("- 經紀業：測試經紀業", markdown)
        self.assertIn("- 電話：0900-000-000", markdown)
        self.assertNotIn("agent@example.com", markdown)
        self.assertIn(
            "- 物件連結：https://sale.591.com.tw/home/house/detail/2/21222842.html",
            markdown,
        )
        self.assertIn("## 房屋資料", markdown)
        self.assertIn("- 登記總面積：45.67坪", markdown)
        self.assertNotIn("土地坪數", markdown)
        self.assertIn("## 屋況特色", markdown)
        self.assertIn("高樓層景觀，座北朝南。", markdown)
        self.assertIn("## 照片", markdown)
        self.assertEqual(
            web_article.extract_image_urls(markdown),
            [
                "https://img.example/house/a.jpeg!1000x.water2.jpeg",
                "https://img.example/house/plan.jpeg!1000x.water2.jpeg",
            ],
        )
        self.assertNotIn("tour.mp4", markdown)
        self.assertEqual(web_article.extract_title(markdown), "景觀三房車位")
        self.assertGreater(web_article.article_body_chars(markdown), 50)

    def test_payload_without_title_raises(self) -> None:
        with self.assertRaises(RuntimeError):
            web_article.sale_591_markdown({"status": 1, "data": {"price": "1萬元"}})

    def test_status_failure_raises(self) -> None:
        with self.assertRaises(RuntimeError) as ctx:
            web_article.sale_591_markdown({"status": 0, "msg": "物件不存在", "data": {}}, house_id="1")
        self.assertIn("status 0", str(ctx.exception))
        self.assertIn("物件不存在", str(ctx.exception))

    def test_fetch_markdown_uses_591_api_not_html(self) -> None:
        import json

        captured: dict = {}

        def fake_urlopen(request, timeout=None):
            captured["url"] = request.full_url
            captured["headers"] = {k.lower(): v for k, v in request.header_items()}
            return _FakeUrlopenResponse(json.dumps(SALE_591_PAYLOAD).encode("utf-8"))

        with patch("urllib.request.urlopen", side_effect=fake_urlopen), patch(
            "curl_cffi.requests.get", side_effect=AssertionError("HTML fetch must not run")
        ):
            markdown = web_article.fetch_markdown(
                "https://sale.591.com.tw/home/house/detail/2/21222842.html"
            )
        self.assertEqual(
            captured["url"],
            "https://bff-house.591.com.tw/v1/touch/sale/detail?"
            "id=S21222842&is_business=0&device_id=airtype&__v__=1&region_id=1&device=touch",
        )
        self.assertEqual(captured["headers"]["accept"], "application/json")
        self.assertEqual(
            captured["headers"]["referer"],
            "https://sale.591.com.tw/home/house/detail/2/21222842.html",
        )
        self.assertEqual(captured["headers"]["origin"], "https://sale.591.com.tw")
        self.assertIn("Chrome/", captured["headers"]["user-agent"])
        self.assertIn("## 屋況特色", markdown)
        self.assertIn("## 照片", markdown)

    def test_591_http_error_is_clear(self) -> None:
        import urllib.error

        error = urllib.error.HTTPError(
            "https://bff-house.591.com.tw/v1/touch/sale/detail", 404, "Not Found", {}, None
        )
        with patch("urllib.request.urlopen", side_effect=error):
            with self.assertRaises(RuntimeError) as ctx:
                web_article.fetch_markdown("https://sale.591.com.tw/home/house/detail/2/999.html")
        self.assertIn("591 sale API returned 404", str(ctx.exception))


class JavaScriptShellTests(unittest.TestCase):
    def test_noscript_shell_is_detected(self) -> None:
        self.assertTrue(
            web_article.is_javascript_shell(
                "# 工作頁－104人力銀行\n\nWe're sorry but vue-start doesn't work properly without JavaScript enabled. Please enable it to continue.\n"
            )
        )
        self.assertTrue(web_article.is_javascript_shell("You need to enable JavaScript to run this app."))

    def test_real_article_mentioning_javascript_is_kept(self) -> None:
        body = "# Guide\n\n" + ("這是一篇很長的文章內容，討論前端框架與效能。" * 20) + "\n\nSome readers may need to enable JavaScript for the demo."
        self.assertFalse(web_article.is_javascript_shell(body))
        self.assertFalse(web_article.is_javascript_shell(ARTICLE_MARKDOWN))

    def test_fetch_markdown_rejects_js_shell_page(self) -> None:
        with patch("curl_cffi.requests.get", return_value=_FakeResponse(200, JS_SHELL_HTML)):
            with self.assertRaises(RuntimeError) as ctx:
                web_article.fetch_markdown("https://spa.example.com/page")
        self.assertIn("JavaScript", str(ctx.exception))


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
        self.assertEqual(payload["warnings"][-1].startswith("Image upload failed"), True)
        self.assertIn("https://cdn.example.com/b.jpg", payload["markdown"])
        self.assertIn("api/assets/a0/thumbnail", payload["markdown"])

    def test_without_immich_keeps_all_original_links(self) -> None:
        payload = _run_article_job_unconfigured()
        self.assertEqual(payload["status"], "completed")
        self.assertTrue(any("Immich is not configured" in warning for warning in payload["warnings"]))
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
        self.assertTrue(any("very little body text" in warning for warning in payload["warnings"]))


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