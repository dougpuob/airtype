"""Public Threads chain collection for the Post Weaver API.

Threads server-renders a JSON payload in ``script[data-sjs]`` on public post
pages.  The payload already contains the visible thread tree, so this module
uses that structured data rather than trying to infer posts from page text.
"""

from __future__ import annotations

from dataclasses import dataclass
from html.parser import HTMLParser
import html
import json
import re
import urllib.parse
import urllib.request
from typing import Any, Iterable


_THREADS_HOSTS = {"threads.com", "www.threads.com", "threads.net", "www.threads.net"}
_POST_PATH = re.compile(r"^/@(?P<author>[^/?#]+)/post/(?P<code>[A-Za-z0-9_-]+)", re.IGNORECASE)


@dataclass(frozen=True)
class ThreadsPost:
    """The small, stable subset Post Weaver needs from a Threads post."""

    id: str
    url: str
    author: str
    text: str

    def as_dict(self) -> dict[str, str]:
        return {"url": self.url, "text": self.text}


class ThreadsChainCollector:
    """Collect the public posts in one author's Threads continuation chain.

    No account, cookie, browser, or private Threads endpoint is required. The
    result is limited to what Threads includes in the public response; private
    or dynamically hidden replies cannot be recovered by any client-side
    parser without another request authorised by Threads.
    """

    def __init__(self, *, max_posts: int = 100, timeout_seconds: int = 20) -> None:
        self.max_posts = max(1, min(int(max_posts), 500))
        self.timeout_seconds = timeout_seconds

    def collect(self, url: str) -> dict[str, Any]:
        canonical_url, author = self._normalize_url(url)
        page = self._fetch(canonical_url)
        payloads = _DataSjsParser.payloads(page)
        posts = self._posts_from_payloads(payloads, author)

        if not posts:
            preview = _meta_content(page, "og:description") or _meta_content(page, "description")
            if preview:
                posts = [ThreadsPost("", canonical_url, author, preview)]

        if not posts:
            raise RuntimeError(
                "Threads did not expose public post data for this URL. The post may be private, "
                "login-walled, deleted, or temporarily rate-limited."
            )
        return {"author": author, "posts": [post.as_dict() for post in posts]}

    def _normalize_url(self, url: str) -> tuple[str, str]:
        parsed = urllib.parse.urlparse(str(url or "").strip())
        if parsed.scheme not in {"http", "https"} or parsed.hostname not in _THREADS_HOSTS:
            raise ValueError("URL must be a public threads.com or threads.net post URL")
        match = _POST_PATH.match(parsed.path)
        if not match:
            raise ValueError("URL must point to a Threads post, such as https://www.threads.com/@author/post/POST_ID")
        path = f"/@{match.group('author')}/post/{match.group('code')}"
        return urllib.parse.urlunparse(("https", "www.threads.com", path, "", "", "")), urllib.parse.unquote(match.group("author"))

    def _fetch(self, url: str) -> str:
        """Fetch with Chrome TLS impersonation when curl-cffi is available."""
        headers = {
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131 Safari/537.36"
            ),
        }
        try:
            from curl_cffi import requests as curl_requests

            response = curl_requests.get(url, headers=headers, impersonate="chrome131", timeout=self.timeout_seconds)
            response.raise_for_status()
            return response.text
        except ImportError:
            request = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                return response.read(3_000_000).decode("utf-8", errors="replace")
        except Exception as error:
            raise RuntimeError(f"Could not open the public Threads post: {error}") from error

    def _posts_from_payloads(self, payloads: Iterable[Any], author: str) -> list[ThreadsPost]:
        posts: list[ThreadsPost] = []
        seen_ids: set[str] = set()
        for payload in payloads:
            for post in _walk_thread_items(payload):
                if post.author.casefold() != author.casefold() or post.id in seen_ids:
                    continue
                seen_ids.add(post.id)
                posts.append(post)
                if len(posts) >= self.max_posts:
                    return posts
        return posts


class _DataSjsParser(HTMLParser):
    """Extract JSON only from the structured public payload scripts."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=False)
        self.payloads: list[Any] = []
        self._inside_data_sjs = False
        self._chunks: list[str] = []

    @classmethod
    def payloads(cls, page: str) -> list[Any]:
        parser = cls()
        parser.feed(page)
        parser.close()
        return parser.payloads

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "script":
            return
        values = {name.lower(): value for name, value in attrs}
        if values.get("type", "").lower() == "application/json" and "data-sjs" in values:
            self._inside_data_sjs = True
            self._chunks = []

    def handle_data(self, data: str) -> None:
        if self._inside_data_sjs:
            self._chunks.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() != "script" or not self._inside_data_sjs:
            return
        self._inside_data_sjs = False
        try:
            self.payloads.append(json.loads("".join(self._chunks)))
        except json.JSONDecodeError:
            # Some unrelated data-sjs blocks are not standalone JSON. Ignore
            # them and retain the parseable post payloads.
            pass
        self._chunks = []


def _walk_thread_items(value: Any) -> Iterable[ThreadsPost]:
    """Depth-first walk of Threads' nested ``thread_items`` response objects."""
    if isinstance(value, dict):
        items = value.get("thread_items")
        if isinstance(items, list):
            for item in items:
                if isinstance(item, dict):
                    post = _threads_post(item.get("post"))
                    if post:
                        yield post
                    # A reply tree may be a sibling of the post inside this
                    # item, so recurse after yielding to preserve page order.
                    for key, child in item.items():
                        if key != "post":
                            yield from _walk_thread_items(child)
        for key, child in value.items():
            if key != "thread_items":
                yield from _walk_thread_items(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk_thread_items(child)


def _threads_post(value: Any) -> ThreadsPost | None:
    if not isinstance(value, dict):
        return None
    user = value.get("user") if isinstance(value.get("user"), dict) else {}
    author = str(user.get("username") or user.get("username_text") or "").strip()
    post_id = str(value.get("pk") or value.get("id") or value.get("code") or "").strip()
    code = str(value.get("code") or "").strip()
    text = _caption_text(value.get("caption"))
    if not author or not post_id or not text:
        return None
    url = f"https://www.threads.com/@{author}/post/{code}" if code else ""
    return ThreadsPost(post_id, url, author, text)


def _caption_text(value: Any) -> str:
    if isinstance(value, str):
        text = value
    elif isinstance(value, dict):
        text = str(value.get("text") or "")
    else:
        return ""
    return re.sub(r"\s+", " ", text).strip()


def _meta_content(page: str, name: str) -> str:
    escaped = re.escape(name)
    match = re.search(
        rf'<meta[^>]+(?:property|name)=["\']{escaped}["\'][^>]+content=["\']([^"\']+)', page, re.IGNORECASE
    ) or re.search(
        rf'<meta[^>]+content=["\']([^"\']+)["\'][^>]+(?:property|name)=["\']{escaped}["\']', page, re.IGNORECASE
    )
    return html.unescape(match.group(1)).strip() if match else ""


def collect_threads_chain(url: str) -> dict[str, Any]:
    """Backward-compatible function used by the FastAPI route."""
    return ThreadsChainCollector().collect(url)
