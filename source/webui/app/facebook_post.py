"""Public Facebook post capture for the Capture Post pipeline.

Facebook serves a logged-out view of public posts (personal posts set to
Public, Page posts, and posts in public groups). The Open Graph tags on that
page carry only the author and a truncated title, but the page also embeds
the post's Relay/GraphQL data as ``<script type="application/json">`` blocks.
This module reads the post ``Story`` from those blocks: the full message
text, the author, the publish time, photo URLs, and video URLs.

Accepted URLs (see ``is_facebook_post_url``):
  * ``facebook.com/share/p/<code>`` / ``share/v/`` / ``share/r/`` share links
  * ``facebook.com/<user>/posts/<id or pfbid>``
  * ``facebook.com/groups/<group>/posts/<id>`` and ``.../permalink/<id>``
  * ``facebook.com/permalink.php?story_fbid=...`` and ``story.php?story_fbid=...``
  * ``facebook.com/photo/?fbid=...`` / ``photo.php?fbid=...``
  * ``facebook.com/<page>/videos/<id>``, ``/reel/<id>``, ``/watch/?v=<id>``,
    ``video.php?v=<id>`` and ``fb.watch/<code>``

Only the logged-out page is read; no cookies are sent. Posts that Facebook
shows only to signed-in users (private groups, friends-only posts, profile
or group-member pages) fail with ``FacebookPostError`` instead of producing
an empty note.
"""

from __future__ import annotations

import datetime
import html as html_lib
import json
import re
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Iterator, Optional

from .note_id import canonical_source_id, note_guid_for_source

FACEBOOK_HOST = "facebook.com"
FB_WATCH_HOST = "fb.watch"
SHORT_HOSTS = ("fb.com", "fb.me")
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)
CURL_IMPERSONATE = "chrome131"
MAX_PAGE_BYTES = 8_000_000

_POST_PATHS = (
    re.compile(r"^/share/(?:p|v|r)/[A-Za-z0-9_-]+/?$", re.IGNORECASE),
    re.compile(r"^/groups/[^/]+/(?:posts|permalink)/[^/]+(?:/[^/]+)?/?$", re.IGNORECASE),
    re.compile(r"^/[^/]+/posts/[^/]+/?(?:[^/]+/?)?$", re.IGNORECASE),
    re.compile(r"^/[^/]+/videos/(?:[^/]+/)?\d+/?$", re.IGNORECASE),
    re.compile(r"^/reel/\d+/?$", re.IGNORECASE),
)
# Paths that name a post through the query string.
_QUERY_POST_PATHS = {
    "/permalink.php": "story_fbid",
    "/story.php": "story_fbid",
    "/photo.php": "fbid",
    "/photo": "fbid",
    "/photo/": "fbid",
    "/video.php": "v",
    "/watch": "v",
    "/watch/": "v",
}
_LOGIN_MARKERS = ("/login", "/checkpoint", "/recover", "login.php")
_JSON_SCRIPT = re.compile(
    r"<script[^>]*type=[\"']application/json[\"'][^>]*>(.*?)</script>",
    re.IGNORECASE | re.DOTALL,
)
_TITLE = re.compile(r"<title[^>]*>(.*?)</title>", re.IGNORECASE | re.DOTALL)
# Subtrees that hold other stories (comments, suggested reels, feeds) or
# duplicate renderings of the post that would confuse "first story wins".
_SKIP_STORY_KEYS = {
    "comments",
    "comment_list_renderer",
    "comment_rendering_instance_for_feed_location",
    "lasso_blue_feed",
    "parent_post_story",
    "attached_story",
    "story_ufi_container",
    "feedback",
    "edges",
}
_NUMERIC_ID = re.compile(r"\d{6,}")
_UNAVAILABLE_AUDIO = {"UNAVAILABLE", "NOT_AVAILABLE", "NO_AUDIO"}


class FacebookPostError(RuntimeError):
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


def is_facebook_host(url: str) -> bool:
    parsed = _parse(url)
    if parsed is None:
        return False
    host = _host(parsed)
    return any(_host_is(host, domain) for domain in (FACEBOOK_HOST, FB_WATCH_HOST, *SHORT_HOSTS))


def is_facebook_post_url(url: str) -> bool:
    """Whether ``url`` points at a single Facebook post, photo, video, or reel."""
    parsed = _parse(url)
    if parsed is None:
        return False
    host = _host(parsed)
    path = urllib.parse.unquote(parsed.path or "")
    if _host_is(host, FB_WATCH_HOST):
        return bool(re.match(r"^/[A-Za-z0-9_-]+/?$", path))
    if not (_host_is(host, FACEBOOK_HOST) or any(_host_is(host, domain) for domain in SHORT_HOSTS)):
        return False
    if any(pattern.match(path) for pattern in _POST_PATHS):
        return True
    query_key = _QUERY_POST_PATHS.get(path.lower())
    if query_key:
        values = urllib.parse.parse_qs(parsed.query).get(query_key) or []
        return any(value.strip() for value in values)
    return False


def _url_ids(url: str) -> set[str]:
    """Numeric ids named in a post URL (post id, story_fbid, video id)."""
    parsed = _parse(url)
    if parsed is None:
        return set()
    ids = set(_NUMERIC_ID.findall(urllib.parse.unquote(parsed.path or "")))
    for key, values in urllib.parse.parse_qs(parsed.query).items():
        if key in {"story_fbid", "fbid", "v", "id"}:
            for value in values:
                ids.update(_NUMERIC_ID.findall(value))
    return ids


def clean_url(url: str) -> str:
    """URL without tracking query (keeps the query keys that name the post)."""
    parsed = _parse(url)
    if parsed is None:
        return str(url or "")
    path = parsed.path or "/"
    query_key = _QUERY_POST_PATHS.get(path.lower())
    query = ""
    if query_key:
        params = urllib.parse.parse_qs(parsed.query)
        kept = [(key, params[key][0]) for key in (query_key, "id") if params.get(key)]
        query = urllib.parse.urlencode(kept)
    host = parsed.netloc.lower()
    if _host_is(_host(parsed), FACEBOOK_HOST):
        host = "www.facebook.com"
    return urllib.parse.urlunparse(("https", host, path, "", query, ""))


_SLUGGED_PATH = re.compile(r"^/([^/]+)/(posts|videos)/[^/]+/(\d+)/?$", re.IGNORECASE)


def identity_url_for(canonical_url: str) -> str:
    """Stable note identity from the page's ``og:url``.

    Facebook puts a slug of the post text in some canonical URLs
    (``/<user>/posts/<slug>/<id>/``); the slug changes when the post is edited,
    so it is dropped to keep the same note id.
    """
    if not canonical_url:
        return ""
    cleaned = clean_url(canonical_url)
    parsed = urllib.parse.urlparse(cleaned)
    match = _SLUGGED_PATH.match(parsed.path or "")
    if match:
        path = f"/{match.group(1)}/{match.group(2)}/{match.group(3)}"
        return urllib.parse.urlunparse((parsed.scheme, parsed.netloc, path, "", parsed.query, ""))
    return cleaned.rstrip("/")


# --------------------------------------------------------------------------- #
# Fetching                                                                     #
# --------------------------------------------------------------------------- #

def _headers() -> dict[str, str]:
    return {
        "User-Agent": USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9,zh-TW;q=0.8",
    }


def fetch_page(url: str, *, timeout_seconds: int = 30) -> tuple[str, int, str]:
    """``(final url, status, html)`` of an anonymous request, following redirects.

    curl_cffi with Chrome TLS impersonation is preferred: Facebook serves the
    logged-out post page (with its Relay data) to a browser-like client.
    """
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
            body = response.read(MAX_PAGE_BYTES).decode("utf-8", errors="replace")
            return response.geturl(), int(response.status), body
    except urllib.error.HTTPError as error:
        return url, int(error.code), ""


def _is_login_wall(final_url: str) -> bool:
    parsed = _parse(final_url)
    if parsed is None:
        return False
    path = (parsed.path or "").lower()
    return any(marker in path for marker in _LOGIN_MARKERS)


# --------------------------------------------------------------------------- #
# Page parsing                                                                 #
# --------------------------------------------------------------------------- #

def _json_blocks(page: str) -> Iterator[Any]:
    for raw in _JSON_SCRIPT.findall(page or ""):
        raw = raw.strip()
        if not raw or raw[0] not in "[{":
            continue
        try:
            yield json.loads(raw)
        except (ValueError, TypeError):
            continue


def _walk(value: Any, path: tuple[str, ...] = ()) -> Iterator[tuple[tuple[str, ...], dict[str, Any]]]:
    stack: list[tuple[tuple[str, ...], Any]] = [(path, value)]
    while stack:
        current_path, current = stack.pop()
        if isinstance(current, dict):
            yield current_path, current
            for key in reversed(list(current.keys())):
                stack.append((current_path + (str(key),), current[key]))
        elif isinstance(current, list):
            for item in reversed(current):
                stack.append((current_path, item))


def _dicts(value: Any) -> Iterator[dict[str, Any]]:
    for _, node in _walk(value):
        yield node


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


def _page_title(page: str) -> str:
    match = _TITLE.search(page or "")
    return html_lib.unescape(match.group(1)).strip() if match else ""


def _text_of(message: Any) -> str:
    if isinstance(message, dict):
        text = message.get("text")
        if isinstance(text, str):
            return text.replace("\r\n", "\n").strip()
    return ""


def _story_text(story: dict[str, Any]) -> str:
    text = _text_of(story.get("message"))
    if text:
        return text
    sections = story.get("comet_sections")
    if isinstance(sections, dict):
        for key in ("content", "message", "message_container"):
            section = sections.get(key)
            for node in _dicts(section):
                text = _text_of(node.get("message"))
                if text:
                    return text
    return ""


def _is_story_candidate(path: tuple[str, ...], node: dict[str, Any]) -> bool:
    if any(key in _SKIP_STORY_KEYS for key in path):
        return False
    if node.get("__typename") == "Story":
        return "attachments" in node or "comet_sections" in node or "message" in node
    return bool(path) and path[-1] == "creation_story" and ("attachments" in node or "message" in node)


def _story_ids(story: dict[str, Any]) -> set[str]:
    ids: set[str] = set()
    for key in ("post_id", "id"):
        value = story.get(key)
        if isinstance(value, (str, int)):
            ids.update(_NUMERIC_ID.findall(str(value)))
    return ids


def _find_story(blocks: list[Any], url_ids: set[str]) -> dict[str, Any]:
    candidates: list[dict[str, Any]] = []
    for block in blocks:
        for path, node in _walk(block):
            if _is_story_candidate(path, node):
                candidates.append(node)
    if not candidates:
        return {}
    if url_ids:
        for story in candidates:
            if _story_ids(story) & url_ids and (_story_text(story) or story.get("attachments")):
                return story
    for story in candidates:
        if _story_text(story) or story.get("attachments"):
            return story
    return candidates[0]


def _actor_name(story: dict[str, Any]) -> str:
    actors = story.get("actors")
    if isinstance(actors, list):
        for actor in actors:
            if isinstance(actor, dict) and isinstance(actor.get("name"), str) and actor["name"].strip():
                return actor["name"].strip()
    sections = story.get("comet_sections")
    for node in _dicts(sections.get("context_layout") if isinstance(sections, dict) else None):
        actors = node.get("actors")
        if isinstance(actors, list):
            for actor in actors:
                if isinstance(actor, dict) and isinstance(actor.get("name"), str) and actor["name"].strip():
                    return actor["name"].strip()
    return ""


def _actor_id(story: dict[str, Any]) -> str:
    """Numeric id of the post's author (the user name is only in some URLs)."""
    actors = story.get("actors")
    if isinstance(actors, list):
        for actor in actors:
            if isinstance(actor, dict) and _NUMERIC_ID.fullmatch(str(actor.get("id") or "")):
                return str(actor["id"])
    return ""


def _video_owner_name(blocks: list[Any]) -> str:
    """Owner of a reel/video page, whose creation story has no ``actors``."""
    for block in blocks:
        for node in _dicts(block):
            owner = node.get("video_owner")
            if isinstance(owner, dict) and isinstance(owner.get("name"), str) and owner["name"].strip():
                return owner["name"].strip()
    return ""


def _group_name(story: dict[str, Any]) -> str:
    target = story.get("to")
    if isinstance(target, dict) and target.get("__typename") == "Group":
        name = target.get("name")
        if isinstance(name, str):
            return name.strip()
    return ""


def _creation_time(story: dict[str, Any]) -> int:
    for node in _dicts(story):
        value = node.get("creation_time")
        if isinstance(value, int) and value > 0:
            return value
    return 0


def _photo_uri(media: dict[str, Any]) -> tuple[str, int]:
    best = ("", -1)
    for key in ("viewer_image", "photo_image", "image", "large_share_image"):
        image = media.get(key)
        if isinstance(image, dict) and isinstance(image.get("uri"), str) and image["uri"].startswith("http"):
            width = image.get("width") if isinstance(image.get("width"), int) else 0
            if width > best[1]:
                best = (image["uri"], width)
    return best


def _video_urls(blocks: list[Any]) -> dict[str, str]:
    """Video id → best progressive MP4 URL, from anywhere in the page data."""
    found: dict[str, str] = {}
    for block in blocks:
        for node in _dicts(block):
            video_id = str(node.get("id") or node.get("video_id") or "")
            if not video_id:
                continue
            for key in ("browser_native_hd_url", "playable_url_quality_hd", "browser_native_sd_url", "playable_url"):
                value = node.get(key)
                if isinstance(value, str) and value.startswith("http"):
                    if video_id not in found:
                        found[video_id] = value
                    break
    return found


def _audio_availability(blocks: list[Any]) -> dict[str, str]:
    availability: dict[str, str] = {}
    for block in blocks:
        for node in _dicts(block):
            if node.get("__typename") == "Video" and isinstance(node.get("audio_availability"), str):
                availability.setdefault(str(node.get("id") or ""), node["audio_availability"])
    return availability


def _story_media(story: dict[str, Any], blocks: list[Any]) -> tuple[list[str], list[dict[str, Any]], int]:
    """``(photo urls, videos, total photo count)`` attached to the story."""
    attachments = story.get("attachments")
    if not attachments:
        sections = story.get("comet_sections")
        if isinstance(sections, dict):
            for node in _dicts(sections.get("content")):
                if node.get("attachments"):
                    attachments = node["attachments"]
                    break
    photos: dict[str, tuple[str, int]] = {}
    order: list[str] = []
    video_ids: list[str] = []
    declared_count = 0
    for node in _dicts(attachments):
        for key in ("all_subattachments", "frame_sublayout_subattachments"):
            sub = node.get(key)
            if isinstance(sub, dict) and isinstance(sub.get("count"), int):
                declared_count = max(declared_count, sub["count"])
        typename = node.get("__typename")
        media_id = str(node.get("id") or "")
        if typename == "Photo":
            uri, width = _photo_uri(node)
            if not uri:
                continue
            key = media_id or uri
            if key not in photos:
                order.append(key)
                photos[key] = (uri, width)
            elif width > photos[key][1]:
                photos[key] = (uri, width)
        elif typename == "Video" and media_id and media_id not in video_ids:
            video_ids.append(media_id)
    direct = _video_urls(blocks)
    audio = _audio_availability(blocks)
    videos = [
        {
            "video_id": video_id,
            "video_url": direct.get(video_id, ""),
            "watch_url": f"https://www.facebook.com/watch/?v={video_id}",
            "has_audio": audio.get(video_id, "AVAILABLE") not in _UNAVAILABLE_AUDIO,
        }
        for video_id in video_ids
    ]
    image_urls = [photos[key][0] for key in order]
    return image_urls, videos, max(declared_count, len(image_urls))


def _shared_story_text(story: dict[str, Any]) -> tuple[str, str]:
    attached = story.get("attached_story")
    if not isinstance(attached, dict):
        return "", ""
    return _story_text(attached), _actor_name(attached)


def parse_post_html(page: str, url: str = "") -> dict[str, Any]:
    """Post fields from a logged-out Facebook post page; ``text`` is "" when absent.

    Returns ``{"text", "author", "group", "published", "image_urls",
    "videos", "photo_count", "shared_text", "shared_author", "canonical_url",
    "title"}``.
    """
    blocks = list(_json_blocks(page))
    story = _find_story(blocks, _url_ids(url))
    text = _story_text(story) if story else ""
    image_urls, videos, photo_count = _story_media(story, blocks) if story else ([], [], 0)
    shared_text, shared_author = _shared_story_text(story) if story else ("", "")
    og_image = _meta(page, "og:image")
    if not image_urls and not videos and og_image and story:
        # Some layouts keep the photo only in Open Graph.
        image_urls = [og_image]
        photo_count = 1
    published = ""
    created = _creation_time(story) if story else 0
    if created:
        published = datetime.datetime.fromtimestamp(created, tz=datetime.timezone.utc).isoformat()
    return {
        "text": text,
        "author": (_actor_name(story) if story else "") or (_video_owner_name(blocks) if story else ""),
        "author_id": _actor_id(story) if story else "",
        "post_id": str(story.get("post_id") or "") if story else "",
        "group": _group_name(story) if story else "",
        "published": published,
        "image_urls": image_urls,
        "videos": videos,
        "photo_count": photo_count,
        "shared_text": shared_text,
        "shared_author": shared_author,
        "canonical_url": _meta(page, "og:url"),
        "title": _meta(page, "og:title") or _page_title(page),
        "description": _meta(page, "og:description"),
        "found_story": bool(story),
    }


def post_markdown(fields: dict[str, Any], post_url: str) -> str:
    """Post text, shared-post quote, photo embeds and a note about hidden photos."""
    parts: list[str] = []
    text = str(fields.get("text") or "").strip()
    if text:
        parts.append(text)
    shared = str(fields.get("shared_text") or "").strip()
    if shared:
        who = str(fields.get("shared_author") or "").strip()
        quoted = "\n".join(f"> {line}" if line else ">" for line in shared.split("\n"))
        parts.append((f"> Shared from {who}:\n>\n" if who else "> Shared post:\n>\n") + quoted)
    images = [item for item in fields.get("image_urls") or [] if item]
    if images:
        parts.append("\n".join(f"![]({item})" for item in images))
    hidden = int(fields.get("photo_count") or 0) - len(images)
    if hidden > 0:
        parts.append(
            f"_{hidden} more photo{'s' if hidden != 1 else ''} in this post "
            f"{'are' if hidden != 1 else 'is'} only shown on Facebook (open the source link)._"
        )
    return "\n\n".join(parts).strip()


# --------------------------------------------------------------------------- #
# Capture                                                                      #
# --------------------------------------------------------------------------- #

def _login_error(url: str) -> FacebookPostError:
    return FacebookPostError(
        "Facebook only shows this post to signed-in users (friends-only, a private group, or a "
        f"profile/member page rather than a single post), so AirType cannot read it: {url}"
    )


def fetch_facebook_post(url: str, *, timeout_seconds: int = 30, fetch=fetch_page) -> dict[str, Any]:
    """Capture one public Facebook post. Raises ``FacebookPostError``."""
    url = str(url or "").strip()
    if not is_facebook_post_url(url):
        raise FacebookPostError("This is not a Facebook post URL.")
    try:
        final_url, status, page = fetch(url, timeout_seconds=timeout_seconds)
    except Exception as error:  # noqa: BLE001 - network errors become capture errors
        raise FacebookPostError(f"Could not open the Facebook post: {error}") from error
    if _is_login_wall(final_url):
        raise _login_error(url)
    if status == 404:
        raise FacebookPostError("Facebook says this post does not exist (404). It may be deleted or private.")
    if status >= 400:
        raise FacebookPostError(f"Facebook returned HTTP {status} for this post.")

    fields = parse_post_html(page, final_url or url)
    post_url = clean_url(final_url or url)
    videos = [video for video in fields["videos"] if video.get("has_audio", True)]
    if not fields["videos"] and not fields["found_story"]:
        # Reels/videos whose page data we could not read: let yt-dlp fetch the audio.
        ids = _url_ids(final_url or url)
        if re.search(r"/(?:reel|videos)/|/watch|video\.php", urllib.parse.urlparse(final_url or url).path or ""):
            videos = [{"video_id": next(iter(ids), ""), "video_url": "", "watch_url": post_url, "has_audio": True}]

    text = fields["text"]
    if not text and fields.get("description"):
        text = fields["description"]
    if not text and not fields["image_urls"] and not videos:
        title = fields.get("title") or ""
        if not fields["found_story"] and title.strip().lower() in {"", "facebook", "log in to facebook", "facebook - log in or sign up"}:
            raise _login_error(url)
        raise FacebookPostError(
            "Facebook did not return the post text, photos or video. The post may be private "
            "or visible only to signed-in users."
        )
    fields["text"] = text
    author = str(fields.get("author") or "")
    group = str(fields.get("group") or "")
    if not author:
        # "<Author> - <text>" (personal) or "<Group> | <text>" page titles.
        page_title = str(fields.get("title") or "")
        if " - " in page_title:
            author = page_title.split(" - ", 1)[0].strip()
    title = f"{author} in {group}" if author and group else (author or group)
    body = post_markdown(fields, post_url) or (f"Facebook post by {author}" if author else "Facebook post")
    identity_url = identity_url_for(fields.get("canonical_url") or "") or post_url
    return {
        "kind": "post",
        "platform": "facebook",
        "url": url,
        "post_url": post_url if post_url != clean_url(url) else "",
        "title": title,
        "author": author,
        "author_id": fields.get("author_id") or "",
        "post_id": fields.get("post_id") or "",
        "group": group,
        "published": fields.get("published") or "",
        "text": text or body,
        "media_urls": list(fields["image_urls"]),
        "videos": [
            {"post_url": video.get("watch_url") or post_url, "video_url": video.get("video_url") or ""}
            for video in videos
        ],
        "markdown": body,
        "guid": note_guid_for_source(identity_url),
        "source_id": canonical_source_id(identity_url),
    }


def is_facebook_video_page(url: str) -> bool:
    """Facebook URLs whose media yt-dlp can download (videos, reels, watch)."""
    parsed = _parse(url)
    if parsed is None:
        return False
    host = _host(parsed)
    if _host_is(host, FB_WATCH_HOST):
        return True
    if not _host_is(host, FACEBOOK_HOST):
        return False
    path = (parsed.path or "").lower()
    return bool(re.search(r"/(?:reel|videos)/|^/watch/?$|^/video\.php$|^/share/[vr]/", path))

