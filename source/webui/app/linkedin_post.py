"""Public LinkedIn post capture for the Capture Post pipeline.

LinkedIn serves a logged-out "guest" page for public posts. That page carries
a schema.org JSON-LD block (``SocialMediaPosting`` for text/image posts,
``VideoObject`` for video posts) with the full post text, author, publish
date, and image URLs, plus the rendered commentary paragraph. This module
reads those instead of the Open Graph preview, whose description LinkedIn
truncates to about 200 characters.

Accepted URLs:
  * ``linkedin.com/posts/<author>_<slug>-activity-<id>-<hash>``
    (also ``-share-<id>`` / ``-ugcPost-<id>``)
  * ``linkedin.com/feed/update/urn:li:activity:<id>`` (also share/ugcPost)
  * ``linkedin.com/embed/feed/update/urn:li:...``
  * ``lnkd.in/p/<code>`` share short links (resolved by following redirects)

Other ``lnkd.in/<code>`` links inside the post text are expanded to their
real targets so the linked-page capture reads the article, not LinkedIn's
"this link will take you to a page that's not on LinkedIn" interstitial.

Public capture needs no login. When LinkedIn sends the logged-out request
to its sign-in wall (members-only posts, authors who limit off-LinkedIn
visibility), the fetch is retried once with the LinkedIn cookies from the
Netscape cookies file in Settings (``[webui.yt-dlp] cookies``, the same file
Threads uses; cookies are filtered per domain, so one file can hold both).
The Cookie header is only ever sent to linkedin.com hosts. Missing, logged
out, or expired cookies each fail with their own error instead of producing
an empty note. LinkedIn articles (``/pulse/``) and profile or
company pages are not posts and stay on the generic web-article pipeline.
"""

from __future__ import annotations

import html as html_lib
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Iterable, Optional

from .note_id import canonical_source_id, note_guid_for_source
from .post_weaver import _cookies_header_for_url

LINKEDIN_HOST = "linkedin.com"
SHORT_HOST = "lnkd.in"
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)
CURL_IMPERSONATE = "chrome131"

_POST_PATH = re.compile(
    r"^/(?:posts/[^/]+|feed/update/[^/]+|embed/feed/update/[^/]+)/?$",
    re.IGNORECASE,
)
_SHORT_POST_PATH = re.compile(r"^/p/[A-Za-z0-9_-]+/?$")
_URN = re.compile(r"urn:li:(activity|share|ugcPost):(\d{10,})", re.IGNORECASE)
_SLUG_ID = re.compile(r"-(activity|share|ugcPost)-(\d{10,})(?=-|/|$)", re.IGNORECASE)
_LD_JSON = re.compile(
    r"<script[^>]*type=[\"']application/ld\+json[\"'][^>]*>(.*?)</script>",
    re.IGNORECASE | re.DOTALL,
)
_COMMENTARY = re.compile(
    r"<p[^>]*data-test-id=[\"']main-feed-activity-card__commentary[\"'][^>]*>(.*?)</p>",
    re.IGNORECASE | re.DOTALL,
)
_POST_TYPES = {
    "socialmediaposting",
    "videoobject",
    "article",
    "newsarticle",
    "blogposting",
    "discussionforumposting",
}
_LOGIN_WALL_MARKERS = ("/authwall", "/login", "/checkpoint", "/uas/login", "/signup")
# LinkedIn's generic placeholder artwork, not post media.
_PLACEHOLDER_IMAGE_PREFIX = "https://static.licdn.com/"
_TITLE_SUFFIX = re.compile(r"\s*\|\s*LinkedIn\s*$", re.IGNORECASE)
_URN_TYPE_CASE = {"activity": "activity", "share": "share", "ugcpost": "ugcPost"}
# lnkd.in/<code> links in post text open LinkedIn's "page not on LinkedIn"
# interstitial; its external_url_click button holds the real target.
_SHORT_LINK = re.compile(r"https?://lnkd\.in/(?!p/)[A-Za-z0-9_-]+")
_INTERSTITIAL_TARGET = re.compile(
    r"<a[^>]*data-tracking-control-name=[\"']external_url_click[\"'][^>]*href=[\"']([^\"']+)[\"']"
    r"|<a[^>]*href=[\"']([^\"']+)[\"'][^>]*data-tracking-control-name=[\"']external_url_click[\"']",
    re.IGNORECASE,
)
MAX_SHORT_LINKS = 10


# LinkedIn's session cookie; a cookies file without it cannot sign in.
SESSION_COOKIE = "li_at"
MAX_REDIRECTS = 8
COOKIES_SETTING_HINT = "Settings → Cookies file ([webui.yt-dlp] cookies)"


class LinkedInPostError(RuntimeError):
    """The post could not be captured (login wall, private, or not found)."""


# --------------------------------------------------------------------------- #
# URL detection                                                                #
# --------------------------------------------------------------------------- #

def _parse(url: str) -> Optional[urllib.parse.ParseResult]:
    try:
        parsed = urllib.parse.urlparse(str(url or "").strip())
    except ValueError:
        return None
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return None
    return parsed


def _host(parsed: urllib.parse.ParseResult) -> str:
    return (parsed.hostname or "").lower().strip(".")


def _host_is(host: str, domain: str) -> bool:
    return host == domain or host.endswith("." + domain)


def is_linkedin_short_post_url(url: str) -> bool:
    """``lnkd.in/p/<code>``: the short link LinkedIn's Share button copies."""
    parsed = _parse(url)
    if parsed is None:
        return False
    return _host_is(_host(parsed), SHORT_HOST) and bool(_SHORT_POST_PATH.match(parsed.path or ""))


def is_linkedin_post_url(url: str) -> bool:
    """Whether ``url`` points at a single LinkedIn feed post."""
    parsed = _parse(url)
    if parsed is None:
        return False
    host = _host(parsed)
    if _host_is(host, SHORT_HOST):
        return bool(_SHORT_POST_PATH.match(parsed.path or ""))
    if not _host_is(host, LINKEDIN_HOST):
        return False
    path = urllib.parse.unquote(parsed.path or "")
    if not _POST_PATH.match(path):
        return False
    return post_urn(url) is not None


def post_urn(url: str) -> Optional[tuple[str, str]]:
    """``(urn type, numeric id)`` for a LinkedIn post URL, or None."""
    parsed = _parse(url)
    if parsed is None or not _host_is(_host(parsed), LINKEDIN_HOST):
        return None
    path = urllib.parse.unquote(parsed.path or "")
    match = _URN.search(path) or _SLUG_ID.search(path)
    if not match:
        return None
    kind = _URN_TYPE_CASE.get(match.group(1).lower(), match.group(1))
    return kind, match.group(2)


def canonical_post_url(url: str) -> str:
    """The guest ``/feed/update/urn:li:<type>:<id>`` URL, or "" when unknown."""
    urn = post_urn(url)
    if not urn:
        return ""
    return f"https://www.linkedin.com/feed/update/urn:li:{urn[0]}:{urn[1]}"


# --------------------------------------------------------------------------- #
# HTML parsing                                                                 #
# --------------------------------------------------------------------------- #

def _ld_objects(page: str) -> Iterable[dict[str, Any]]:
    for raw in _LD_JSON.findall(page or ""):
        try:
            data = json.loads(raw.strip())
        except (ValueError, TypeError):
            continue
        stack = data if isinstance(data, list) else [data]
        for item in stack:
            if not isinstance(item, dict):
                continue
            graph = item.get("@graph")
            if isinstance(graph, list):
                for node in graph:
                    if isinstance(node, dict):
                        yield node
            yield item


def _ld_type(item: dict[str, Any]) -> str:
    value = item.get("@type")
    if isinstance(value, list):
        value = next((entry for entry in value if isinstance(entry, str)), "")
    return str(value or "").lower()


def _first_post_object(page: str) -> dict[str, Any]:
    for item in _ld_objects(page):
        if _ld_type(item) in _POST_TYPES:
            return item
    return {}


def _text(value: Any) -> str:
    if isinstance(value, str):
        return html_lib.unescape(value).replace("\r\n", "\n").strip()
    return ""


def _person(value: Any) -> tuple[str, str]:
    if isinstance(value, list):
        value = next((entry for entry in value if isinstance(entry, dict)), {})
    if isinstance(value, dict):
        return _text(value.get("name")), _text(value.get("url"))
    return _text(value), ""


def _image_urls(value: Any) -> list[str]:
    urls: list[str] = []
    items = value if isinstance(value, list) else [value]
    for item in items:
        if isinstance(item, dict):
            item = item.get("url") or item.get("contentUrl")
        candidate = _text(item)
        if candidate.lower().startswith(("http://", "https://")):
            urls.append(candidate)
    return urls


def _strip_tags(fragment: str) -> str:
    text = re.sub(r"<br\s*/?>", "\n", fragment or "", flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", "", text)
    text = html_lib.unescape(text)
    lines = [line.rstrip() for line in text.replace("\r\n", "\n").split("\n")]
    return "\n".join(lines).strip()


def _meta(page: str, name: str) -> str:
    escaped = re.escape(name)
    for pattern in (
        rf'<meta[^>]+(?:property|name)=["\']{escaped}["\'][^>]+content=["\']([^"\']*)',
        rf'<meta[^>]+content=["\']([^"\']*)["\'][^>]+(?:property|name)=["\']{escaped}["\']',
    ):
        match = re.search(pattern, page or "", flags=re.IGNORECASE)
        if match:
            return html_lib.unescape(match.group(1)).strip()
    return ""


def _unique(values: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if value and value not in seen:
            seen.add(value)
            result.append(value)
    return result


def parse_post_html(page: str, url: str = "") -> dict[str, Any]:
    """Post fields from a LinkedIn guest post page; ``text`` is "" when absent.

    Returns ``{"text", "headline", "title", "author", "author_url",
    "published", "image_urls", "video_url", "canonical_url"}``.
    """
    post = _first_post_object(page)
    commentary_match = _COMMENTARY.search(page or "")
    commentary = _strip_tags(commentary_match.group(1)) if commentary_match else ""

    text = (
        _text(post.get("articleBody"))
        or _text(post.get("description"))
        or commentary
        or _text(post.get("headline"))
        or _meta(page, "og:description")
        or _meta(page, "description")
    )

    author, author_url = _person(post.get("author") or post.get("creator"))
    headline = _text(post.get("headline"))
    og_title = _TITLE_SUFFIX.sub("", _meta(page, "og:title"))
    if not author:
        match = re.search(r"\|\s*(.+?)\s+posted on the topic", og_title)
        if match:
            author = match.group(1).strip()

    images = _image_urls(post.get("image"))
    if _ld_type(post) == "videoobject":
        images.extend(_image_urls(post.get("thumbnailUrl")))
    if not images:
        og_image = _meta(page, "og:image")
        if og_image and not og_image.startswith(_PLACEHOLDER_IMAGE_PREFIX):
            images.append(og_image)
    images = [item for item in _unique(images) if not item.startswith(_PLACEHOLDER_IMAGE_PREFIX)]

    video_url = _text(post.get("contentUrl")) if _ld_type(post) == "videoobject" else ""
    canonical = _text(post.get("@id")) or _meta(page, "og:url") or url

    return {
        "text": text,
        "headline": headline,
        "title": headline or og_title,
        "author": author,
        "author_url": author_url,
        "published": _text(post.get("datePublished")),
        "image_urls": images,
        "video_url": video_url,
        "canonical_url": canonical,
    }


_CODE_BLOCK = re.compile(r"<code[^>]*>(.*?)</code>", re.IGNORECASE | re.DOTALL)


def _code_json_blobs(page: str) -> Iterable[Any]:
    """JSON payloads LinkedIn's signed-in pages embed in hidden <code> blocks."""
    for raw in _CODE_BLOCK.findall(page or ""):
        text = raw.strip()
        if text.startswith("<!--") and text.endswith("-->"):
            text = text[4:-3].strip()
        if not text.startswith(("{", "[")):
            continue
        try:
            yield json.loads(html_lib.unescape(text))
        except (ValueError, TypeError):
            continue


def _walk(value: Any) -> Iterable[dict[str, Any]]:
    stack = [value]
    while stack:
        item = stack.pop()
        if isinstance(item, dict):
            yield item
            stack.extend(item.values())
        elif isinstance(item, list):
            stack.extend(item)


def _nested_text(value: Any) -> str:
    """``{"text": {"text": "..."}}`` / ``{"text": "..."}`` style text values."""
    for _ in range(3):
        if isinstance(value, str):
            return value.strip()
        if isinstance(value, dict):
            value = value.get("text")
        else:
            return ""
    return value.strip() if isinstance(value, str) else ""


def _vector_image_urls(value: Any) -> list[str]:
    urls: list[str] = []
    for node in _walk(value):
        root = node.get("rootUrl")
        artifacts = node.get("artifacts")
        if isinstance(root, str) and isinstance(artifacts, list) and artifacts:
            best = max(
                (item for item in artifacts if isinstance(item, dict)),
                key=lambda item: int(item.get("width") or 0),
                default=None,
            )
            segment = best.get("fileIdentifyingUrlPathSegment") if best else ""
            if isinstance(segment, str) and segment:
                urls.append(root + segment)
    return urls


_EXPANDABLE_TEXT = re.compile(r"<(span|div|p)\b[^>]*data-testid=[\"']expandable-text-box[\"'][^>]*>", re.IGNORECASE)
_TAG = re.compile(r"<(/?)([a-zA-Z][a-zA-Z0-9]*)\b[^>]*?(/?)>")
_CONTROL_MENU_AUTHOR = re.compile(r"aria-label=[\"']Open control menu for post by ([^\"']+)[\"']", re.IGNORECASE)
_FEEDSHARE_IMAGE = re.compile(r"<img[^>]+src=[\"'](https://media\.licdn\.com/dms/image/[^\"']*feedshare[^\"']*)[\"']", re.IGNORECASE)
_VOID_TAGS = {"br", "img", "hr", "input", "meta", "link", "source", "wbr"}


def _element_inner_html(page: str, start: int, tag: str) -> str:
    """Inner HTML of the element whose opening tag ends at ``start``."""
    depth = 1
    for match in _TAG.finditer(page, start):
        closing, name, self_closing = match.group(1), match.group(2).lower(), match.group(3)
        if name != tag or self_closing or name in _VOID_TAGS:
            continue
        depth += -1 if closing else 1
        if depth == 0:
            return page[start:match.start()]
    return page[start:]


def parse_sdui_post_html(page: str, url: str = "") -> dict[str, Any]:
    """Post fields from LinkedIn's signed-in server-rendered (SDUI) feed page.

    The first ``data-testid="expandable-text-box"`` element is the post body
    (later ones are comments); the author comes from the post's control-menu
    label, and images are the ``feedshare`` media between the post body and
    the first comment.
    """
    boxes = list(_EXPANDABLE_TEXT.finditer(page or ""))
    fields = parse_post_html("", url)
    fields["text"] = ""
    if not boxes:
        return fields
    first = boxes[0]
    text = _strip_tags(_element_inner_html(page, first.end(), first.group(1).lower()))
    header = page[max(0, first.start() - 20000):first.start()]
    authors = _CONTROL_MENU_AUTHOR.findall(header)
    region_end = boxes[1].start() if len(boxes) > 1 else first.end() + 60000
    images = _unique(html_lib.unescape(item) for item in _FEEDSHARE_IMAGE.findall(page[first.end():region_end]))
    first_line = text.splitlines()[0][:200] if text else ""
    fields.update(
        text=text,
        headline=first_line,
        title=first_line,
        author=html_lib.unescape(authors[-1]).strip() if authors else "",
        image_urls=images,
        canonical_url=url,
    )
    return fields


def parse_member_post_html(page: str, url: str = "", urn: Optional[tuple[str, str]] = None) -> dict[str, Any]:
    """Best-effort post fields from a signed-in LinkedIn page.

    Signed-in pages carry no JSON-LD. The current server-rendered (SDUI) page
    is read first; older pages keep the feed update in hidden ``<code>``
    JSON (``commentary.text.text``, ``actor.name.text``). The update whose
    URN matches the post id wins; otherwise the longest commentary.
    """
    sdui = parse_sdui_post_html(page, url)
    if sdui["text"]:
        return sdui
    post_id = urn[1] if urn else ""
    best: Optional[dict[str, Any]] = None
    best_score = (-1, -1)
    for blob in _code_json_blobs(page):
        for node in _walk(blob):
            text = _nested_text(node.get("commentary"))
            if not text:
                continue
            matches = 1 if post_id and post_id in json.dumps(node, ensure_ascii=False)[:20000] else 0
            score = (matches, len(text))
            if score > best_score:
                best, best_score = node, score
    if best is None:
        empty = parse_post_html("", url)
        og_text = _meta(page, "og:description")
        empty["text"] = og_text if og_text and "linkedin" not in og_text.lower()[:40] else ""
        return empty
    actor = best.get("actor") if isinstance(best.get("actor"), dict) else {}
    images = [item for item in _unique(_vector_image_urls(best.get("content"))) if item]
    text = _nested_text(best.get("commentary"))
    return {
        "text": text,
        "headline": text.splitlines()[0][:200] if text else "",
        "title": text.splitlines()[0][:200] if text else "",
        "author": _nested_text(actor.get("name")),
        "author_url": _text(actor.get("navigationUrl")),
        "published": "",
        "image_urls": images,
        "video_url": "",
        "canonical_url": url,
    }


def post_markdown(fields: dict[str, Any]) -> str:
    """Original-content Markdown: byline, post text, then image embeds.

    Same shape as ``post_weaver.posts_to_markdown`` (text followed by image
    embeds) so Immich rewriting and the clip template treat it like any post.
    The byline is plain text so the linked-page capture does not fetch the
    author's profile.
    """
    parts: list[str] = []
    byline = " · ".join(
        item for item in (str(fields.get("author") or ""), str(fields.get("published") or "")[:10]) if item
    )
    if byline:
        parts.append(f"LinkedIn post by {byline}")
    text = str(fields.get("text") or "").strip()
    if text:
        parts.append(text)
    for image in fields.get("image_urls") or []:
        parts.append(f"![]({image})")
    if fields.get("video_url"):
        parts.append("(This post includes a video; open the source link to watch it.)")
    return "\n\n".join(parts).strip()


# --------------------------------------------------------------------------- #
# Fetching                                                                     #
# --------------------------------------------------------------------------- #

def _headers() -> dict[str, str]:
    return {
        "User-Agent": USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9,zh-TW;q=0.8",
    }


def _sends_cookie_to(url: str) -> bool:
    parsed = _parse(url)
    return parsed is not None and parsed.scheme == "https" and _host_is(_host(parsed), LINKEDIN_HOST)


def _fetch_with_cookie(url: str, cookie_header: str, *, timeout_seconds: int) -> tuple[str, int, str]:
    """Follow redirects by hand so the Cookie header never leaves linkedin.com."""
    from curl_cffi import requests as curl_requests

    current = url
    for _ in range(MAX_REDIRECTS + 1):
        headers = _headers()
        if _sends_cookie_to(current):
            headers["Cookie"] = cookie_header
        try:
            response = curl_requests.get(
                current,
                headers=headers,
                timeout=timeout_seconds,
                allow_redirects=False,
                impersonate=CURL_IMPERSONATE,
            )
        except TypeError:
            response = curl_requests.get(current, headers=headers, timeout=timeout_seconds, allow_redirects=False)
        status = int(response.status_code)
        location = response.headers.get("location") or ""
        if status in {301, 302, 303, 307, 308} and location:
            current = urllib.parse.urljoin(current, location)
            continue
        return current, status, response.text or ""
    return current, 310, ""


def fetch_page(url: str, *, timeout_seconds: int = 30, cookie_header: str = "") -> tuple[str, int, str]:
    """``(final url, status, html)``, following redirects.

    Without ``cookie_header`` this is an anonymous request. With it, the
    header is sent to linkedin.com hops only.
    """
    if cookie_header:
        return _fetch_with_cookie(url, cookie_header, timeout_seconds=timeout_seconds)
    try:
        from curl_cffi import requests as curl_requests
    except ImportError:
        curl_requests = None
    if curl_requests is not None:
        try:
            response = curl_requests.get(
                url,
                headers=_headers(),
                timeout=timeout_seconds,
                allow_redirects=True,
                impersonate=CURL_IMPERSONATE,
            )
        except TypeError:
            response = curl_requests.get(url, headers=_headers(), timeout=timeout_seconds, allow_redirects=True)
        return str(response.url or url), int(response.status_code), response.text or ""
    request = urllib.request.Request(url, headers=_headers())
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            body = response.read(8_000_000).decode("utf-8", errors="replace")
            return response.geturl(), int(response.status), body
    except urllib.error.HTTPError as error:
        return url, int(error.code), ""


def resolve_short_link(url: str, *, timeout_seconds: int = 30, fetch=fetch_page) -> str:
    """Target of an ``lnkd.in/<code>`` link, or "" when it cannot be resolved."""
    try:
        final_url, status, page = fetch(url, timeout_seconds=timeout_seconds)
    except Exception:
        return ""
    if status >= 400:
        return ""
    final_host = (urllib.parse.urlparse(final_url).hostname or "").lower()
    if final_host and not _host_is(final_host, SHORT_HOST) and not _host_is(final_host, LINKEDIN_HOST):
        return final_url
    match = _INTERSTITIAL_TARGET.search(page or "")
    if not match:
        return ""
    target = html_lib.unescape(match.group(1) or match.group(2) or "").strip()
    return target if target.lower().startswith(("http://", "https://")) else ""


def expand_short_links(text: str, *, timeout_seconds: int = 30, fetch=fetch_page) -> str:
    """Replace ``lnkd.in`` links in post text with the pages they point to.

    Unresolved links are left as they are. This lets the linked-page capture
    fetch the real article instead of LinkedIn's interstitial.
    """
    links = _unique(_SHORT_LINK.findall(text or ""))[:MAX_SHORT_LINKS]
    for link in links:
        target = resolve_short_link(link, timeout_seconds=timeout_seconds, fetch=fetch)
        if target:
            text = re.sub(re.escape(link) + r"(?![A-Za-z0-9_-])", lambda _m: target, text)
    return text


def _is_login_wall(final_url: str) -> bool:
    path = (urllib.parse.urlparse(final_url).path or "").lower()
    return any(path.startswith(marker) for marker in _LOGIN_WALL_MARKERS)


_WALL_REDIRECT_KEYS = ("session_redirect", "redirect", "redirect_uri", "session_redirect_url")


def wall_redirect_target(wall_url: str) -> str:
    """The LinkedIn page a sign-in/sign-up wall URL would return to, or "".

    LinkedIn sends logged-out visitors to ``/signup/cold-join?session_redirect=
    <post URL>``; the post URL (and its URN) is still in that query string.
    """
    try:
        query = urllib.parse.parse_qs(urllib.parse.urlparse(wall_url).query)
    except ValueError:
        return ""
    for key in _WALL_REDIRECT_KEYS:
        for value in query.get(key) or []:
            target = value.strip()
            parsed = _parse(target)
            if parsed is not None and _host_is(_host(parsed), LINKEDIN_HOST):
                return target
    return ""


def _members_only_error(post_url: str) -> LinkedInPostError:
    where = canonical_post_url(post_url) or post_url
    return LinkedInPostError(
        "LinkedIn only shows this post to signed-in members: every logged-out request for "
        f"{where} was redirected to its sign-up page, and the page held no post data. "
        "The author has probably limited who can see the post (or their profile) off LinkedIn. "
        "To capture members-only posts, export your linkedin.com cookies (Netscape format) "
        f"into the cookies file in {COOKIES_SETTING_HINT}."
    )


def linkedin_cookie_header(cookies_path: str, url: str = "https://www.linkedin.com/feed/") -> str:
    """Cookie header for linkedin.com from a Netscape cookies file.

    Raises ``LinkedInPostError`` when the configured file is missing, or has
    no LinkedIn session cookie. Returns "" when no file is configured.
    """
    path = str(cookies_path or "").strip()
    if not path:
        return ""
    try:
        header = _cookies_header_for_url(path, url)
    except (OSError, RuntimeError) as error:
        raise LinkedInPostError(
            f"The cookies file in {COOKIES_SETTING_HINT} could not be read ({path}): {type(error).__name__}."
        ) from error
    names = {part.split("=", 1)[0].strip() for part in header.split(";") if "=" in part}
    if SESSION_COOKIE not in names:
        raise LinkedInPostError(
            f"LinkedIn only shows this post to signed-in members, and the cookies file ({path}) has no "
            f"LinkedIn login cookie ({SESSION_COOKIE}). Export your linkedin.com cookies while signed in "
            "and add them to that file."
        )
    return header


def _try_post_pages(
    post_url: str,
    *,
    fetch,
    timeout_seconds: int,
    cookie_header: str = "",
) -> tuple[Optional[dict[str, Any]], bool, int]:
    """``(fields or None, hit sign-in wall, last HTTP status)`` over the post URL forms."""
    login_wall = False
    last_status = 0
    for candidate in _unique([canonical_post_url(post_url), post_url]):
        try:
            if cookie_header:
                final_url, status, page = fetch(candidate, timeout_seconds=timeout_seconds, cookie_header=cookie_header)
            else:
                final_url, status, page = fetch(candidate, timeout_seconds=timeout_seconds)
        except Exception:
            continue
        last_status = status
        if _is_login_wall(final_url):
            login_wall = True
            continue
        if status >= 400:
            continue
        fields = parse_post_html(page, final_url)
        if not fields["text"] and cookie_header:
            fields = parse_member_post_html(page, final_url, post_urn(post_url))
        if fields["text"]:
            return fields, login_wall, last_status
    return None, login_wall, last_status


def fetch_linkedin_post(
    url: str,
    *,
    timeout_seconds: int = 30,
    fetch=fetch_page,
    cookies_path: str = "",
) -> dict[str, Any]:
    """Capture one LinkedIn post. Raises ``LinkedInPostError``.

    The guest ``/feed/update/urn:li:...`` page is tried first because it is
    the most consistent logged-out view; the submitted URL is the fallback.
    Only when LinkedIn answers with its sign-in wall are the same URLs
    retried with the LinkedIn cookies from ``cookies_path``.
    """
    url = str(url or "").strip()
    if not is_linkedin_post_url(url):
        raise LinkedInPostError("This is not a LinkedIn post URL.")

    post_url = url
    short_page: Optional[tuple[str, int, str]] = None
    if is_linkedin_short_post_url(url):
        try:
            short_page = fetch(url, timeout_seconds=timeout_seconds)
        except Exception as error:
            raise LinkedInPostError(f"Could not open the LinkedIn short link: {error}") from error
        post_url = short_page[0] or url
        if not post_urn(post_url) and _is_login_wall(post_url):
            # The short link was redirected to a sign-in wall. The wall URL still
            # names the post; retry the post's own URL forms before giving up.
            post_url = wall_redirect_target(post_url) or post_url
        if not post_urn(post_url):
            if _is_login_wall(post_url):
                raise _members_only_error(url)
            raise LinkedInPostError(f"The LinkedIn short link did not lead to a post: {post_url}")

    fields, login_wall, last_status = _try_post_pages(post_url, fetch=fetch, timeout_seconds=timeout_seconds)
    # The short link already landed on the post page; use it if the retries failed.
    if fields is None and short_page is not None and short_page[1] < 400 and not _is_login_wall(short_page[0]):
        parsed_fields = parse_post_html(short_page[2], short_page[0])
        if parsed_fields["text"]:
            fields = parsed_fields
    if fields is not None:
        fields["text"] = expand_short_links(fields["text"], timeout_seconds=timeout_seconds, fetch=fetch)
        return _payload(url, post_url, fields)

    if login_wall:
        cookie_header = linkedin_cookie_header(cookies_path, canonical_post_url(post_url) or post_url)
        if not cookie_header:
            raise _members_only_error(post_url)
        fields, still_walled, last_status = _try_post_pages(
            post_url, fetch=fetch, timeout_seconds=timeout_seconds, cookie_header=cookie_header
        )
        if fields is not None:
            # Short links in the text are public redirects; resolve them without cookies.
            fields["text"] = expand_short_links(fields["text"], timeout_seconds=timeout_seconds, fetch=fetch)
            payload = _payload(url, post_url, fields)
            payload["used_cookies"] = True
            return payload
        if still_walled:
            raise LinkedInPostError(
                f"LinkedIn still asked for sign-in with the cookies from {COOKIES_SETTING_HINT}. "
                "The LinkedIn session in that file has probably expired or been logged out; "
                "export fresh linkedin.com cookies while signed in and replace them in the file."
            )
        if last_status == 404:
            raise LinkedInPostError(
                "LinkedIn says this post does not exist (404) even when signed in. It may be deleted, "
                "or visible only to the author's connections."
            )
        raise LinkedInPostError(
            "Signed in with the LinkedIn cookies, but the page held no post text AirType can read. "
            "LinkedIn may have changed its signed-in page layout."
        )
    if last_status == 404:
        raise LinkedInPostError("LinkedIn says this post does not exist (404). It may be deleted or private.")
    raise LinkedInPostError(
        "LinkedIn did not return the post text. The post may be private or LinkedIn may be limiting anonymous access; try again later."
    )


def _payload(url: str, post_url: str, fields: dict[str, Any]) -> dict[str, Any]:
    identity_url = canonical_post_url(post_url) or post_url
    parsed = urllib.parse.urlparse(post_url)
    clean_post_url = urllib.parse.urlunparse((parsed.scheme or "https", parsed.netloc, parsed.path.rstrip("/"), "", "", ""))
    title = fields.get("headline") or fields.get("title") or ""
    author = str(fields.get("author") or "")
    if author and title and author not in title:
        title = f"{author}: {title}"
    return {
        "kind": "post",
        "platform": "linkedin",
        "url": url,
        # Set only for short links: the post page the lnkd.in link resolved to.
        "post_url": clean_post_url if is_linkedin_short_post_url(url) else "",
        "title": title or author,
        "author": author,
        "author_url": fields.get("author_url") or "",
        "published": fields.get("published") or "",
        "text": fields["text"],
        "media_urls": list(fields.get("image_urls") or []),
        "video_url": fields.get("video_url") or "",
        "markdown": post_markdown(fields),
        "guid": note_guid_for_source(identity_url),
        "source_id": canonical_source_id(identity_url),
    }
