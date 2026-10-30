"""Tests for public LinkedIn post capture (URL detection, parsing, fetching)."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from app import clip_pipeline
from app import clip_requests
from app import known_sources
from app import linkedin_post
from app import web_article
from app.note_id import canonical_source_id, note_guid_for_source

FIXTURES = Path(__file__).parent / "fixtures"
POST_URL = "https://www.linkedin.com/posts/daniel-example_ai-brake-activity-7518967102335184897-GxNh"
FEED_URL = "https://www.linkedin.com/feed/update/urn:li:activity:7518967102335184897"
SHARE_URL = "https://www.linkedin.com/posts/tarun92057_nvidia-gb300-share-7520917171590561792-Tatx/?utm_source=social_share_send&rcm=abc"
SHORT_URL = "https://lnkd.in/p/gsEmVmpk"
TEXT_LINK = "https://lnkd.in/dBHWBrSU"
LINK_TARGET = "https://techcrunch.com/2026/10/10/ai-emergency-brake/"
INTERSTITIAL = (
    "<h1>This link will take you to a page that’s not on LinkedIn</h1>"
    '<a class="artdeco-button" data-tracking-control-name="external_url_click" '
    f'data-tracking-will-navigate href="{LINK_TARGET}">{LINK_TARGET}</a>'
)


def fixture(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


class LinkedInUrlDetectionTests(unittest.TestCase):
    def test_post_urls_are_detected(self) -> None:
        for url in (
            POST_URL,
            FEED_URL,
            SHARE_URL,
            "https://linkedin.com/feed/update/urn:li:share:7520917171590561792/",
            "https://www.linkedin.com/feed/update/urn%3Ali%3AugcPost%3A7520917171590561792",
            "https://www.linkedin.com/embed/feed/update/urn:li:activity:7518982780551340032?compact=true",
            "https://tw.linkedin.com/posts/someone_slug-ugcPost-7520917171590561792-AbCd",
            SHORT_URL,
        ):
            with self.subTest(url=url):
                self.assertTrue(linkedin_post.is_linkedin_post_url(url))

    def test_non_post_urls_are_not_detected(self) -> None:
        for url in (
            "https://www.linkedin.com/in/satyanadella",
            "https://www.linkedin.com/pulse/some-article-author-abc",
            "https://www.linkedin.com/company/microsoft/",
            "https://www.linkedin.com/feed/",
            "https://www.linkedin.com/posts/no-activity-id-here",
            "https://lnkd.in/gEjFzJWC",
            "https://notlinkedin.com/posts/x-activity-7518967102335184897-a",
            "https://linkedin.com.evil.io/posts/x-activity-7518967102335184897-a",
            "not a url",
        ):
            with self.subTest(url=url):
                self.assertFalse(linkedin_post.is_linkedin_post_url(url))

    def test_urn_and_canonical_url(self) -> None:
        self.assertEqual(linkedin_post.post_urn(POST_URL), ("activity", "7518967102335184897"))
        self.assertEqual(linkedin_post.post_urn(SHARE_URL), ("share", "7520917171590561792"))
        self.assertEqual(linkedin_post.canonical_post_url(POST_URL), FEED_URL)
        self.assertEqual(
            linkedin_post.canonical_post_url("https://www.linkedin.com/feed/update/urn:li:ugcpost:7520917171590561792"),
            "https://www.linkedin.com/feed/update/urn:li:ugcPost:7520917171590561792",
        )
        self.assertEqual(linkedin_post.canonical_post_url(SHORT_URL), "")


class LinkedInRoutingTests(unittest.TestCase):
    def test_posts_route_to_capture_post(self) -> None:
        for url in (POST_URL, FEED_URL, SHARE_URL, SHORT_URL):
            with self.subTest(url=url):
                self.assertEqual(known_sources.route_for_url(url), "capture-post")
                self.assertEqual(known_sources.match_known_source(url).pipeline, "capture-post")

    def test_other_linkedin_pages_stay_on_web_article(self) -> None:
        for url in (
            "https://www.linkedin.com/pulse/some-article-author-abc",
            "https://www.linkedin.com/in/satyanadella",
            "https://lnkd.in/gEjFzJWC",
        ):
            with self.subTest(url=url):
                self.assertIsNone(known_sources.match_known_source(url))
                self.assertEqual(known_sources.route_for_url(url), "web-article")

    def test_web_article_job_rejects_linkedin_posts_with_hint(self) -> None:
        self.assertIn("Capture Post", known_sources.known_source_hint(POST_URL))
        with self.assertRaises(web_article.KnownSourceError):
            web_article.start_job(POST_URL)

    def test_known_sources_payload_lists_path_source(self) -> None:
        payload = known_sources.known_sources_payload()
        self.assertEqual(payload["path_sources"][0]["host"], "linkedin.com")


class LinkedInNoteIdTests(unittest.TestCase):
    def test_slug_and_feed_urls_share_an_identity(self) -> None:
        self.assertEqual(canonical_source_id(POST_URL), "linkedin:activity:7518967102335184897")
        self.assertEqual(canonical_source_id(FEED_URL), "linkedin:activity:7518967102335184897")
        self.assertEqual(note_guid_for_source(POST_URL), note_guid_for_source(FEED_URL + "/"))
        self.assertEqual(canonical_source_id(SHARE_URL), "linkedin:share:7520917171590561792")

    def test_non_post_linkedin_pages_keep_web_identity(self) -> None:
        self.assertEqual(
            canonical_source_id("https://www.linkedin.com/pulse/some-article?utm_source=x"),
            "web:https://www.linkedin.com/pulse/some-article",
        )


class LinkedInParseTests(unittest.TestCase):
    def test_text_post_uses_full_article_body(self) -> None:
        fields = linkedin_post.parse_post_html(fixture("linkedin_post_guest.html"), POST_URL)
        self.assertTrue(fields["text"].startswith("🚨 AI needs an emergency brake. Are we building one fast enough?"))
        self.assertIn("control, monitor, and stop them", fields["text"])  # beyond the og:description cut
        self.assertIn("https://lnkd.in/dBHWBrSU", fields["text"])
        self.assertEqual(fields["author"], "Daniel Example")
        self.assertEqual(fields["published"], "2026-10-22T09:30:52.849Z")
        self.assertEqual(len(fields["image_urls"]), 1)
        self.assertIn("articleshare", fields["image_urls"][0])
        self.assertEqual(fields["video_url"], "")

    def test_video_post_uses_description_and_thumbnail(self) -> None:
        fields = linkedin_post.parse_post_html(fixture("linkedin_video_guest.html"), FEED_URL)
        self.assertIn("Today in Cologne", fields["text"])
        self.assertEqual(fields["author"], "Satya Nadella")
        self.assertEqual(len(fields["image_urls"]), 1)
        self.assertIn("videocover", fields["image_urls"][0])
        self.assertIn("mp4", fields["video_url"])

    def test_commentary_and_og_fallbacks(self) -> None:
        page = (
            '<meta property="og:title" content="X | Jane Doe posted on the topic | LinkedIn">'
            '<p class="x" data-test-id="main-feed-activity-card__commentary">Hello <a href="#">world</a><br>line 2</p>'
        )
        fields = linkedin_post.parse_post_html(page)
        self.assertEqual(fields["text"], "Hello world\nline 2")
        self.assertEqual(fields["author"], "Jane Doe")
        og_only = linkedin_post.parse_post_html('<meta property="og:description" content="Only preview">')
        self.assertEqual(og_only["text"], "Only preview")
        self.assertEqual(linkedin_post.parse_post_html("<html></html>")["text"], "")

    def test_markdown_has_byline_text_and_images(self) -> None:
        fields = linkedin_post.parse_post_html(fixture("linkedin_post_guest.html"), POST_URL)
        markdown = linkedin_post.post_markdown(fields)
        self.assertTrue(markdown.startswith("LinkedIn post by Daniel Example · 2026-10-22\n\n🚨"))
        self.assertIn("![](https://media.licdn.com/dms/image/sync/v2/D4E27AQF/", markdown)
        self.assertNotIn("linkedin.com/in/", markdown)  # no profile link for linked-page capture


class LinkedInFetchTests(unittest.TestCase):
    def test_fetches_canonical_guest_page_first(self) -> None:
        calls: list[str] = []

        def fetch(url: str, *, timeout_seconds: int = 30):
            calls.append(url)
            if url == TEXT_LINK:
                return url, 200, INTERSTITIAL
            return url, 200, fixture("linkedin_post_guest.html")

        payload = linkedin_post.fetch_linkedin_post(POST_URL, fetch=fetch)
        self.assertEqual(calls, [FEED_URL, TEXT_LINK])
        self.assertIn(f"Read more: {LINK_TARGET}", payload["text"])
        self.assertNotIn(TEXT_LINK, payload["markdown"])
        self.assertEqual(payload["kind"], "post")
        self.assertEqual(payload["platform"], "linkedin")
        self.assertEqual(payload["author"], "Daniel Example")
        self.assertEqual(payload["title"], "Daniel Example: 🚨 AI needs an emergency brake.")
        self.assertEqual(payload["guid"], note_guid_for_source(FEED_URL))
        self.assertEqual(payload["source_id"], "linkedin:activity:7518967102335184897")
        self.assertIn("control, monitor, and stop them", payload["markdown"])
        self.assertEqual(len(payload["media_urls"]), 1)

    def test_falls_back_to_submitted_url(self) -> None:
        calls: list[str] = []

        def fetch(url: str, *, timeout_seconds: int = 30):
            calls.append(url)
            if url == FEED_URL:
                return url, 200, "<html>app shell without post data</html>"
            return url, 200, fixture("linkedin_post_guest.html")

        payload = linkedin_post.fetch_linkedin_post(POST_URL, fetch=fetch)
        self.assertEqual(calls[:2], [FEED_URL, POST_URL])
        self.assertEqual(payload["author"], "Daniel Example")

    def test_short_link_resolves_to_post(self) -> None:
        resolved = SHARE_URL
        calls: list[str] = []

        def fetch(url: str, *, timeout_seconds: int = 30):
            calls.append(url)
            if url == SHORT_URL:
                return resolved, 200, fixture("linkedin_post_guest.html")
            return url, 200, fixture("linkedin_post_guest.html")

        payload = linkedin_post.fetch_linkedin_post(SHORT_URL, fetch=fetch)
        self.assertEqual(calls[0], SHORT_URL)
        self.assertEqual(calls[1], "https://www.linkedin.com/feed/update/urn:li:share:7520917171590561792")
        self.assertEqual(payload["url"], SHORT_URL)
        self.assertEqual(payload["post_url"], "https://www.linkedin.com/posts/tarun92057_nvidia-gb300-share-7520917171590561792-Tatx")
        self.assertEqual(payload["source_id"], "linkedin:share:7520917171590561792")

    def test_login_wall_raises_clear_error(self) -> None:
        def fetch(url: str, *, timeout_seconds: int = 30):
            return "https://www.linkedin.com/authwall?trk=x", 200, "<html>Sign in</html>"

        with self.assertRaisesRegex(linkedin_post.LinkedInPostError, "signed-in members"):
            linkedin_post.fetch_linkedin_post(POST_URL, fetch=fetch)

    def test_short_link_on_signup_wall_retries_the_post_urls(self) -> None:
        # lnkd.in/p/gaRVGfRK (2026-10-28) landed on /signup/cold-join with the
        # post in session_redirect; the post URL forms must still be tried.
        wall = (
            "https://www.linkedin.com/signup/cold-join?session_redirect="
            "https%3A%2F%2Fwww%2Elinkedin%2Ecom%2Ffeed%2Fupdate%2Furn%3Ali%3Ashare%3A7519403765402058753"
            "%3Futm_source%3Dsocial_share_send&trk=public_post"
        )
        feed = "https://www.linkedin.com/feed/update/urn:li:share:7519403765402058753"
        calls: list[str] = []

        def fetch(url: str, *, timeout_seconds: int = 30):
            calls.append(url)
            if url == SHORT_URL:
                return wall, 200, "<html><title>Sign Up | LinkedIn</title></html>"
            if url == feed:
                return url, 200, fixture("linkedin_post_guest.html")
            return url, 200, INTERSTITIAL

        payload = linkedin_post.fetch_linkedin_post(SHORT_URL, fetch=fetch)
        self.assertEqual(calls[:2], [SHORT_URL, feed])
        self.assertEqual(payload["author"], "Daniel Example")
        self.assertEqual(payload["source_id"], "linkedin:share:7519403765402058753")
        self.assertEqual(payload["post_url"], feed)

    def test_short_link_members_only_post_names_the_post(self) -> None:
        wall = (
            "https://www.linkedin.com/signup/cold-join?session_redirect="
            "https%3A%2F%2Fwww%2Elinkedin%2Ecom%2Ffeed%2Fupdate%2Furn%3Ali%3Ashare%3A7519403765402058753"
        )
        calls: list[str] = []

        def fetch(url: str, *, timeout_seconds: int = 30):
            calls.append(url)
            return wall, 200, "<html><title>Sign Up | LinkedIn</title></html>"

        with self.assertRaisesRegex(linkedin_post.LinkedInPostError, "signed-in members.*urn:li:share:7519403765402058753"):
            linkedin_post.fetch_linkedin_post(SHORT_URL, fetch=fetch)
        self.assertIn("https://www.linkedin.com/feed/update/urn:li:share:7519403765402058753", calls)

    def test_wall_redirect_target(self) -> None:
        self.assertEqual(
            linkedin_post.wall_redirect_target(
                "https://www.linkedin.com/signup/cold-join?session_redirect="
                "https%3A%2F%2Fwww%2Elinkedin%2Ecom%2Ffeed%2Fupdate%2Furn%3Ali%3Aactivity%3A1234567890123"
            ),
            "https://www.linkedin.com/feed/update/urn:li:activity:1234567890123",
        )
        self.assertEqual(
            linkedin_post.wall_redirect_target(
                "https://www.linkedin.com/authwall?session_redirect=https%3A%2F%2Fevil.example%2F"
            ),
            "",
        )
        self.assertEqual(linkedin_post.wall_redirect_target("https://www.linkedin.com/authwall"), "")

    def test_not_found_raises_clear_error(self) -> None:
        def fetch(url: str, *, timeout_seconds: int = 30):
            return url, 404, ""

        with self.assertRaisesRegex(linkedin_post.LinkedInPostError, "404"):
            linkedin_post.fetch_linkedin_post(FEED_URL, fetch=fetch)

    def test_rejects_non_post_urls(self) -> None:
        with self.assertRaises(linkedin_post.LinkedInPostError):
            linkedin_post.fetch_linkedin_post("https://www.linkedin.com/in/satyanadella", fetch=mock.Mock())


class LinkedInShortLinkTests(unittest.TestCase):
    def test_resolves_interstitial_and_redirects(self) -> None:
        self.assertEqual(
            linkedin_post.resolve_short_link(TEXT_LINK, fetch=lambda url, **_: (url, 200, INTERSTITIAL)),
            LINK_TARGET,
        )
        self.assertEqual(
            linkedin_post.resolve_short_link(TEXT_LINK, fetch=lambda url, **_: (LINK_TARGET, 200, "<html></html>")),
            LINK_TARGET,
        )
        self.assertEqual(linkedin_post.resolve_short_link(TEXT_LINK, fetch=lambda url, **_: (url, 404, "")), "")

    def test_expand_leaves_unresolved_links_and_skips_post_short_links(self) -> None:
        seen: list[str] = []

        def fetch(url: str, **_):
            seen.append(url)
            return url, 200, "<html>no target</html>"

        text = f"See {TEXT_LINK} and {SHORT_URL}"
        self.assertEqual(linkedin_post.expand_short_links(text, fetch=fetch), text)
        self.assertEqual(seen, [TEXT_LINK])


WALL = "https://www.linkedin.com/signup/cold-join?session_redirect=https%3A%2F%2Fwww%2Elinkedin%2Ecom%2Ffeed"
FAKE_SESSION = "fake-session-value"


def write_cookies(directory: str, lines: list[str]) -> str:
    path = Path(directory) / "cookies.txt"
    path.write_text("# Netscape HTTP Cookie File\n" + "\n".join(lines) + "\n", encoding="utf-8")
    return str(path)


LINKEDIN_COOKIES = [
    f"#HttpOnly_.www.linkedin.com\tTRUE\t/\tTRUE\t2000000000\tli_at\t{FAKE_SESSION}",
    ".linkedin.com\tTRUE\t/\tTRUE\t2000000000\tJSESSIONID\tajax:123",
    ".threads.com\tTRUE\t/\tTRUE\t2000000000\tsessionid\tthreads-only",
]


class LinkedInCookieTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def walled_until_cookie(self, calls: list[tuple[str, str]]):
        def fetch(url: str, *, timeout_seconds: int = 30, cookie_header: str = ""):
            calls.append((url, cookie_header))
            if url.startswith("https://lnkd.in/"):
                return url, 200, INTERSTITIAL
            if not cookie_header:
                return WALL, 200, "<html><title>Sign Up | LinkedIn</title></html>"
            return url, 200, fixture("linkedin_post_guest.html")

        return fetch

    def test_public_first_then_retry_with_linkedin_cookies(self) -> None:
        cookies = write_cookies(self.temporary.name, LINKEDIN_COOKIES)
        calls: list[tuple[str, str]] = []
        payload = linkedin_post.fetch_linkedin_post(
            POST_URL, fetch=self.walled_until_cookie(calls), cookies_path=cookies
        )
        self.assertTrue(payload["used_cookies"])
        self.assertEqual(payload["author"], "Daniel Example")
        self.assertEqual(calls[0], (FEED_URL, ""))  # anonymous first
        self.assertEqual(calls[1], (POST_URL, ""))
        url, header = calls[2]
        self.assertEqual(url, FEED_URL)
        self.assertIn(f"li_at={FAKE_SESSION}", header)
        self.assertIn("JSESSIONID=ajax:123", header)
        self.assertNotIn("threads-only", header)  # other domains stay out
        self.assertEqual([c for u, c in calls if u.startswith("https://lnkd.in/")], [""])

    def test_public_posts_never_read_cookies(self) -> None:
        calls: list[tuple[str, str]] = []

        def fetch(url: str, *, timeout_seconds: int = 30, cookie_header: str = ""):
            calls.append((url, cookie_header))
            return url, 200, fixture("linkedin_post_guest.html")

        payload = linkedin_post.fetch_linkedin_post(
            POST_URL, fetch=fetch, cookies_path=str(Path(self.temporary.name) / "missing.txt")
        )
        self.assertNotIn("used_cookies", payload)
        self.assertTrue(all(cookie == "" for _, cookie in calls))

    def test_wall_without_cookies_file_explains_setting(self) -> None:
        with self.assertRaisesRegex(linkedin_post.LinkedInPostError, r"signed-in members.*Cookies file"):
            linkedin_post.fetch_linkedin_post(POST_URL, fetch=self.walled_until_cookie([]), cookies_path="")

    def test_missing_cookies_file(self) -> None:
        missing = str(Path(self.temporary.name) / "missing.txt")
        with self.assertRaisesRegex(linkedin_post.LinkedInPostError, "could not be read"):
            linkedin_post.fetch_linkedin_post(POST_URL, fetch=self.walled_until_cookie([]), cookies_path=missing)

    def test_cookies_file_without_linkedin_session(self) -> None:
        cookies = write_cookies(self.temporary.name, [LINKEDIN_COOKIES[2]])
        with self.assertRaisesRegex(linkedin_post.LinkedInPostError, "no LinkedIn login cookie") as raised:
            linkedin_post.fetch_linkedin_post(POST_URL, fetch=self.walled_until_cookie([]), cookies_path=cookies)
        self.assertNotIn("threads-only", str(raised.exception))

    def test_expired_cookies_still_walled(self) -> None:
        cookies = write_cookies(self.temporary.name, LINKEDIN_COOKIES)

        def fetch(url: str, *, timeout_seconds: int = 30, cookie_header: str = ""):
            return WALL, 200, "<html>Sign Up</html>"

        with self.assertRaisesRegex(linkedin_post.LinkedInPostError, "expired") as raised:
            linkedin_post.fetch_linkedin_post(POST_URL, fetch=fetch, cookies_path=cookies)
        self.assertNotIn(FAKE_SESSION, str(raised.exception))

    def test_short_link_members_only_post_uses_cookies(self) -> None:
        cookies = write_cookies(self.temporary.name, LINKEDIN_COOKIES)
        wall = (
            "https://www.linkedin.com/signup/cold-join?session_redirect="
            "https%3A%2F%2Fwww%2Elinkedin%2Ecom%2Ffeed%2Fupdate%2Furn%3Ali%3Ashare%3A7519403765402058753"
        )
        feed = "https://www.linkedin.com/feed/update/urn:li:share:7519403765402058753"
        calls: list[tuple[str, str]] = []

        def fetch(url: str, *, timeout_seconds: int = 30, cookie_header: str = ""):
            calls.append((url, cookie_header))
            if url.startswith("https://lnkd.in/") and url != SHORT_URL:
                return url, 200, INTERSTITIAL
            if not cookie_header:
                return wall, 200, "<html>Sign Up</html>"
            return url, 200, fixture("linkedin_post_guest.html")

        payload = linkedin_post.fetch_linkedin_post(SHORT_URL, fetch=fetch, cookies_path=cookies)
        self.assertTrue(payload["used_cookies"])
        self.assertEqual(calls[0], (SHORT_URL, ""))
        self.assertIn((feed, ""), calls)
        self.assertTrue(any(url == feed and cookie for url, cookie in calls))

    def test_sdui_member_page_parser(self) -> None:
        page = (
            '<button aria-label="Open control menu for post by Igor Example"></button>'
            '<p componentkey="k"><span class="a" tabindex="-1" data-testid="expandable-text-box">'
            'First line of the post.<br/>  Second <span class="x"><a href="https://www.linkedin.com/in/x">'
            '<strong>Someone</strong></a></span> line &amp; more<br/>Source: https://lnkd.in/daQfrtPZ</span></p>'
            '<img src="https://media.licdn.com/dms/image/v2/D4D22AQF/feedshare-shrink_480/0/1?e=1&amp;v=beta">'
            '<img src="https://media.licdn.com/dms/image/v2/C5603/profile-displayphoto-shrink_100_100/0/1">'
            '<span data-testid="expandable-text-box">A comment, not the post</span>'
            '<img src="https://media.licdn.com/dms/image/v2/Z/feedshare-shrink_480/0/2">'
        )
        fields = linkedin_post.parse_member_post_html(page, FEED_URL, ("share", "1"))
        self.assertEqual(
            fields["text"],
            "First line of the post.\n  Second Someone line & more\nSource: https://lnkd.in/daQfrtPZ",
        )
        self.assertEqual(fields["author"], "Igor Example")
        self.assertEqual(
            fields["image_urls"], ["https://media.licdn.com/dms/image/v2/D4D22AQF/feedshare-shrink_480/0/1?e=1&v=beta"]
        )
        self.assertEqual(fields["title"], "First line of the post.")

    def test_member_page_blob_parser(self) -> None:
        blob = {
            "included": [
                {"entityUrn": "urn:li:fsd_update:(urn:li:activity:1,FEED)", "commentary": {"text": {"text": "other"}}},
                {
                    "entityUrn": "urn:li:fsd_update:(urn:li:share:7519403765402058753,FEED)",
                    "commentary": {"text": {"text": "Members-only post body\nsecond line"}},
                    "actor": {"name": {"text": "Igor Example"}, "navigationUrl": "https://www.linkedin.com/in/igor"},
                    "content": {"imageComponent": {"images": [{"attributes": [{"vectorImage": {
                        "rootUrl": "https://media.licdn.com/dms/image/v2/X/",
                        "artifacts": [
                            {"width": 200, "fileIdentifyingUrlPathSegment": "small"},
                            {"width": 1280, "fileIdentifyingUrlPathSegment": "large"},
                        ],
                    }}]}]}},
                },
            ]
        }
        page = '<code style="display: none" id="bpr-guid-1"><!--' + json.dumps(blob).replace('"', "&quot;") + "--></code>"
        fields = linkedin_post.parse_member_post_html(page, "", ("share", "7519403765402058753"))
        self.assertEqual(fields["text"], "Members-only post body\nsecond line")
        self.assertEqual(fields["author"], "Igor Example")
        self.assertEqual(fields["image_urls"], ["https://media.licdn.com/dms/image/v2/X/large"])

    def test_manual_redirects_drop_cookie_off_linkedin(self) -> None:
        sent: list[tuple[str, str]] = []

        class Response:
            def __init__(self, status: int, location: str = "", text: str = "") -> None:
                self.status_code = status
                self.headers = {"location": location} if location else {}
                self.text = text

        def get(url: str, *, headers: dict, **_kwargs):
            sent.append((url, headers.get("Cookie", "")))
            if url == FEED_URL:
                return Response(302, "https://example.com/elsewhere")
            return Response(200, text="done")

        from curl_cffi import requests as curl_requests

        with mock.patch.object(curl_requests, "get", side_effect=get):
            final_url, status, page = linkedin_post.fetch_page(FEED_URL, cookie_header="li_at=x")
        self.assertEqual((final_url, status, page), ("https://example.com/elsewhere", 200, "done"))
        self.assertEqual(sent, [(FEED_URL, "li_at=x"), ("https://example.com/elsewhere", "")])

    def test_cookie_header_only_sent_to_linkedin_hosts(self) -> None:
        self.assertTrue(linkedin_post._sends_cookie_to("https://www.linkedin.com/feed/update/urn:li:share:1"))
        self.assertFalse(linkedin_post._sends_cookie_to("https://lnkd.in/abc"))
        self.assertFalse(linkedin_post._sends_cookie_to("https://evil.example/linkedin.com"))
        self.assertFalse(linkedin_post._sends_cookie_to("http://www.linkedin.com/feed/"))


class LinkedInPublicPostDispatchTests(unittest.TestCase):
    def test_load_public_post_uses_linkedin_fetcher(self) -> None:
        from app import main as webui

        with mock.patch.object(webui.linkedin_post, "fetch_linkedin_post", return_value={"markdown": "ok"}) as fetch:
            with mock.patch.object(
                webui, "_read_backend_config_settings", return_value={"ytdlp": {"cookies": " /tmp/c.txt "}}
            ):
                self.assertEqual(webui._load_public_post(POST_URL), {"markdown": "ok"})
            fetch.assert_called_once_with(POST_URL, cookies_path="/tmp/c.txt")

    def test_linkedin_cookies_path_prefers_settings_then_data_dir(self) -> None:
        from app import main as webui

        with mock.patch.object(webui, "_read_backend_config_settings", return_value={"ytdlp": {"cookies": "/x/c.txt"}}):
            self.assertEqual(webui._linkedin_cookies_path(), "/x/c.txt")
        with tempfile.TemporaryDirectory() as directory:
            default = str(Path(directory) / "cookies.txt")
            with mock.patch.object(webui, "_read_backend_config_settings", return_value={"ytdlp": {}}), mock.patch.object(
                webui, "LINKEDIN_COOKIES_PATH", default
            ):
                self.assertEqual(webui._linkedin_cookies_path(), "")
                Path(default).write_text("# Netscape HTTP Cookie File\n", encoding="utf-8")
                self.assertEqual(webui._linkedin_cookies_path(), default)
        with mock.patch.object(
            webui.linkedin_post,
            "fetch_linkedin_post",
            side_effect=linkedin_post.LinkedInPostError("LinkedIn asked for sign-in"),
        ), mock.patch.object(webui, "_read_backend_config_settings", return_value={}):
            with self.assertRaisesRegex(ValueError, "sign-in"):
                webui._load_public_post(POST_URL)


class LinkedInRunPostTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        clip_requests.configure(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_run_post_writes_linkedin_draft(self) -> None:
        created = clip_requests.create(kind="post", source=SHORT_URL)

        def fetch(url: str, *, timeout_seconds: int = 30):
            return (SHARE_URL if url == SHORT_URL else url), 200, fixture("linkedin_post_guest.html")

        def chat(_system: str, user: str, step: str) -> str:
            return "潤稿" if step == "polish" else "標題"

        with mock.patch.object(clip_pipeline.web_article, "fetch_markdown", side_effect=RuntimeError("skip")):
            clip_pipeline.run_post(
                created["id"],
                SHORT_URL,
                settings=lambda: {"web_to_markdown": {}, "immich": {}, "capture_post": {"ai_title_enabled": False}},
                chat=chat,
                collect_threads=lambda _url: {},
                fetch_public_post=lambda url: linkedin_post.fetch_linkedin_post(url, fetch=fetch),
            )

        stored = clip_requests.get(created["id"])
        assert stored is not None
        self.assertEqual(stored["status"], "completed")
        self.assertIn("LinkedIn post by Daniel Example", stored["content"])
        self.assertEqual(
            stored["sources"],
            [SHORT_URL, "https://www.linkedin.com/posts/tarun92057_nvidia-gb300-share-7520917171590561792-Tatx"],
        )
        self.assertEqual(stored["guid"], note_guid_for_source("https://www.linkedin.com/feed/update/urn:li:share:7520917171590561792"))
        self.assertIn("capture-post", stored["tags"])


if __name__ == "__main__":
    unittest.main()
