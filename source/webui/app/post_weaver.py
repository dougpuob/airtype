"""Utilities for importing the public portion of a Threads post chain.

Threads does not provide a stable, unauthenticated API for reading a post and
its continuation posts.  This module deliberately uses the public web page and
returns only text the page exposes without signing in.
"""

from __future__ import annotations

import html
import re
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


_THREADS_HOSTS = {"threads.com", "www.threads.com", "threads.net", "www.threads.net"}
_POST_PATH = re.compile(r"^/@(?P<author>[^/?#]+)/post/(?P<id>[A-Za-z0-9_-]+)", re.IGNORECASE)
_POST_LINK = re.compile(
    r"(?:https?://(?:www\.)?threads\.(?:com|net))?"
    r"(?P<path>/@(?P<author>[^/?#\"'<>\s]+)/post/[A-Za-z0-9_-]+)(?:[?#][^\"'<>\s]*)?",
    re.IGNORECASE,
)


def collect_threads_chain(url: str) -> dict[str, Any]:
    """Collect publicly visible posts belonging to a Threads continuation.

    The return value intentionally matches the shape consumed by the Post
    Weaver page: ``{"author": str, "posts": [{"url": str, "text": str}]}``.
    A browser is used when available because Threads commonly renders post text
    client-side.  A small HTML metadata fallback keeps importing a single
    public post useful on hosts where Playwright's browser is not installed.
    """
    normalized_url, author = _validate_threads_url(url)
    browser_error: RuntimeError | None = None
    try:
        page_html = _load_page_with_browser(normalized_url)
    except RuntimeError as error:
        # Playwright is an enhancement, not a hard dependency for the single
        # post preview path.  It is especially useful on the first run, before
        # `playwright install chromium` has been performed.
        page_html = ""
        browser_error = error
    posts = _posts_from_page(page_html, author)

    if not posts:
        fallback = _public_preview(normalized_url)
        if fallback:
            posts = [{"url": normalized_url, "text": fallback}]

    if not posts:
        if browser_error:
            raise browser_error
        raise RuntimeError(
            "Threads did not expose any public post text. Open the post in a browser "
            "and paste the visible text into Post Weaver instead."
        )

    return {"author": author, "posts": posts}


def _validate_threads_url(url: str) -> tuple[str, str]:
    candidate = str(url or "").strip()
    parsed = urllib.parse.urlparse(candidate)
    if parsed.scheme not in {"http", "https"} or parsed.hostname not in _THREADS_HOSTS:
        raise ValueError("URL must be a public threads.com or threads.net post URL")

    match = _POST_PATH.match(parsed.path)
    if not match:
        raise ValueError("URL must point to a Threads post, for example https://www.threads.com/@author/post/POST_ID")

    # Tracking parameters are not part of a post's identity and make de-duping
    # in the browser UI unreliable.
    normalized = urllib.parse.urlunparse(("https", "www.threads.com", parsed.path, "", "", ""))
    return normalized, urllib.parse.unquote(match.group("author")).lstrip("@")


def _load_page_with_browser(url: str) -> str:
    try:
        from playwright.sync_api import sync_playwright
    except ImportError as error:
        raise RuntimeError("Threads import needs the optional Playwright dependency. Run ./scripts/start-webui.sh again.") from error

    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            try:
                page = browser.new_page(
                    user_agent=(
                        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131 Safari/537.36"
                    )
                )
                page.goto(url, wait_until="domcontentloaded", timeout=30_000)
                # Continuation posts are lazy-loaded.  A few short scrolls
                # make the currently public portion of the chain part of the
                # DOM without attempting to crawl an author's whole feed.
                for _ in range(4):
                    page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
                    page.wait_for_timeout(700)
                    for button in page.locator("button").all():
                        try:
                            label = (button.inner_text(timeout=250) or "").strip().casefold()
                            if label in {"view more replies", "show more replies", "view more"}:
                                button.click(timeout=500)
                        except Exception:
                            # Buttons can disappear while Threads re-renders a
                            # reply group; the next pass will see the new DOM.
                            continue
                page.wait_for_timeout(500)
                return page.content()
            finally:
                browser.close()
    except Exception as error:
        # The exception normally means that the browser binary has not been
        # installed.  Do not silently return an empty chain: that produces a
        # deceptively successful import in the UI.
        raise RuntimeError(
            "Could not open the public Threads page. If this is a new installation, "
            "run '.venv/bin/python -m playwright install chromium'."
        ) from error


def _posts_from_page(page_html: str, author: str) -> list[dict[str, str]]:
    """Extract visible article blocks without depending on Threads CSS classes."""
    article_blocks = re.findall(r"<article\b[^>]*>(.*?)</article>", page_html, flags=re.IGNORECASE | re.DOTALL)
    posts: list[dict[str, str]] = []
    seen_urls: set[str] = set()

    for block in article_blocks:
        url = _first_post_url(block, author)
        text = _visible_text(block)
        if url and text and url not in seen_urls:
            posts.append({"url": url, "text": text})
            seen_urls.add(url)

    # Server-rendered Threads pages occasionally omit article elements.  In
    # that case their Open Graph description is still a faithful public preview
    # of the initial post, and is preferable to returning nothing.
    if not posts:
        canonical = _first_post_url(page_html, author)
        description = _meta_content(page_html, "og:description") or _meta_content(page_html, "description")
        if canonical and description:
            posts.append({"url": canonical, "text": description})

    return posts[:20]


def _first_post_url(markup: str, author: str) -> str:
    for match in _POST_LINK.finditer(html.unescape(markup).replace("\\/", "/")):
        if match.group("author").casefold() == author.casefold():
            return urllib.parse.urlunparse(("https", "www.threads.com", match.group("path"), "", "", ""))
    return ""


def _visible_text(markup: str) -> str:
    markup = re.sub(r"<(script|style|svg|noscript)\b[^>]*>.*?</\1>", " ", markup, flags=re.IGNORECASE | re.DOTALL)
    text = re.sub(r"<[^>]+>", " ", markup)
    text = html.unescape(text)
    text = re.sub(r"\s+", " ", text).strip()
    # Thread page chrome can be the entire extracted article if a post is not
    # public; avoid adding such noise as a post.
    return "" if len(text) < 2 or text.casefold() in {"threads", "log in", "sign up"} else text


def _meta_content(page_html: str, name: str) -> str:
    escaped = re.escape(name)
    match = re.search(
        rf'<meta[^>]+(?:property|name)=["\']{escaped}["\'][^>]+content=["\']([^"\']+)',
        page_html,
        flags=re.IGNORECASE,
    ) or re.search(
        rf'<meta[^>]+content=["\']([^"\']+)["\'][^>]+(?:property|name)=["\']{escaped}["\']',
        page_html,
        flags=re.IGNORECASE,
    )
    return html.unescape(match.group(1)).strip() if match else ""


def _public_preview(url: str) -> str:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (compatible; AirType Post Weaver/1.0)",
            "Accept": "text/html,application/xhtml+xml",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            page_html = response.read(1_500_000).decode("utf-8", errors="replace")
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
        return ""
    return _meta_content(page_html, "og:description") or _meta_content(page_html, "description")
