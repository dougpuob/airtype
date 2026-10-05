"""Deterministic clip IDs: a canonical source name plus UUID v5.

Recapturing the same source reuses the Obsidian ``guid:`` and the Immich
tag, instead of minting a new identity each time. The v5 namespace is
frozen; changing it rewrites every future note GUID.

Local files have no URL and still use a random UUID v4 at the call site.
"""

from __future__ import annotations

import re
import urllib.parse
import uuid
from typing import Optional


# Frozen AirType clip namespace. Do not change.
CLIP_NAMESPACE = uuid.UUID("8f3c2a10-6b4d-4e91-9a77-2c1d0b7e4a11")

_THREADS_POST = re.compile(
    r"^/@(?P<author>[^/?#]+)/post/(?P<code>[A-Za-z0-9_-]+)/?$",
    re.IGNORECASE,
)
_THREADS_SHARE = re.compile(r"^/share/(?P<share_id>[A-Za-z0-9_-]+)/?$", re.IGNORECASE)
_BILIBILI_VIDEO = re.compile(r"^/video/(?P<id>BV[0-9A-Za-z]+|av\d+)/?", re.IGNORECASE)
_INSTAGRAM_MEDIA = re.compile(
    r"^/(?:p|reel|reels|tv)/(?P<code>[A-Za-z0-9_-]+)/?",
    re.IGNORECASE,
)
_TIKTOK_VIDEO = re.compile(
    r"^/@(?P<user>[^/?#]+)/video/(?P<video_id>\d+)/?",
    re.IGNORECASE,
)

_TRACKING_KEYS = {
    "fbclid",
    "gclid",
    "gbraid",
    "wbraid",
    "mc_eid",
    "igshid",
    "si",
    "pp",
    "ref",
    "ref_src",
    "ref_url",
    "feature",
    "embeds_referring_euri",
    "embeds_referring_origin",
    "spm_id_from",
    "vd_source",
}
_TRACKING_PREFIXES = ("utm_",)

_YOUTUBE_TIME_KEYS = {"t", "start", "time_continue", "start_radio"}


def canonical_source_id(url: str) -> str:
    """Stable identity string for a clip URL, or ``""`` when it has none."""
    parsed = _parse_http_url(url)
    if parsed is None:
        return ""
    host = (parsed.hostname or "").lower().strip(".")
    if not host:
        return ""

    youtube_id = _youtube_video_id(host, parsed)
    if youtube_id:
        return f"youtube:{youtube_id}"

    threads_id = _threads_id(host, parsed)
    if threads_id:
        return f"threads:{threads_id}"

    bili_id = _bilibili_id(host, parsed)
    if bili_id:
        return f"bilibili:{bili_id}"

    ig_id = _instagram_id(host, parsed)
    if ig_id:
        return f"instagram:{ig_id}"

    tiktok_id = _tiktok_id(host, parsed)
    if tiktok_id:
        return f"tiktok:{tiktok_id}"

    return f"web:{_canonical_web_url(parsed)}"


def note_guid_for_source(url: str) -> str:
    """UUID v5 for ``url``, or a random UUID v4 when the URL has no identity."""
    source_id = canonical_source_id(url)
    if not source_id:
        return str(uuid.uuid4())
    return str(uuid.uuid5(CLIP_NAMESPACE, source_id))


def _parse_http_url(url: str) -> Optional[urllib.parse.ParseResult]:
    raw = str(url or "").strip()
    if not raw:
        return None
    try:
        parsed = urllib.parse.urlparse(raw)
    except ValueError:
        return None
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return None
    return parsed


def _host_is(host: str, domain: str) -> bool:
    return host == domain or host.endswith("." + domain)


def _youtube_video_id(host: str, parsed: urllib.parse.ParseResult) -> str:
    if not (_host_is(host, "youtube.com") or _host_is(host, "youtu.be")):
        return ""
    path = parsed.path or ""
    parts = [part for part in path.split("/") if part]
    if _host_is(host, "youtu.be") and parts:
        return parts[0]
    if parts:
        if parts[0] in {"shorts", "embed", "live", "v", "e"} and len(parts) > 1:
            return parts[1]
        if parts[0] == "watch" and len(parts) > 1:
            return parts[1]
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=False)
    values = query.get("v") or []
    return str(values[0]) if values else ""


def _threads_id(host: str, parsed: urllib.parse.ParseResult) -> str:
    if not (_host_is(host, "threads.com") or _host_is(host, "threads.net")):
        return ""
    path = parsed.path or ""
    post = _THREADS_POST.match(path)
    if post:
        author = urllib.parse.unquote(post.group("author")).lower()
        return f"@{author}/post/{post.group('code')}"
    share = _THREADS_SHARE.match(path)
    if share:
        return f"share/{share.group('share_id')}"
    return ""


def _bilibili_id(host: str, parsed: urllib.parse.ParseResult) -> str:
    if not (_host_is(host, "bilibili.com") or _host_is(host, "b23.tv")):
        return ""
    if _host_is(host, "b23.tv"):
        return ""
    match = _BILIBILI_VIDEO.match(parsed.path or "")
    if not match:
        return ""
    video_id = match.group("id")
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=False)
    part = (query.get("p") or [""])[0]
    if part and part != "1":
        return f"{video_id}/p{part}"
    return video_id


def _instagram_id(host: str, parsed: urllib.parse.ParseResult) -> str:
    if not _host_is(host, "instagram.com"):
        return ""
    match = _INSTAGRAM_MEDIA.match(parsed.path or "")
    return match.group("code") if match else ""


def _tiktok_id(host: str, parsed: urllib.parse.ParseResult) -> str:
    if not _host_is(host, "tiktok.com"):
        return ""
    match = _TIKTOK_VIDEO.match(parsed.path or "")
    return match.group("video_id") if match else ""


def _canonical_web_url(parsed: urllib.parse.ParseResult) -> str:
    host = (parsed.hostname or "").lower().strip(".")
    port = parsed.port
    if port and port not in {80, 443}:
        netloc = f"{host}:{port}"
    else:
        netloc = host
    path = parsed.path or "/"
    if path != "/" and path.endswith("/"):
        path = path[:-1]
    query_pairs = [
        (key, value)
        for key, value in urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        if not _is_tracking_query(key)
    ]
    query_pairs.sort(key=lambda item: (item[0].lower(), item[1]))
    query = urllib.parse.urlencode(query_pairs)
    return urllib.parse.urlunparse(("https", netloc, path, "", query, ""))


def _is_tracking_query(key: str) -> bool:
    lowered = str(key or "").lower()
    if lowered in _TRACKING_KEYS or lowered in _YOUTUBE_TIME_KEYS:
        return True
    return any(lowered.startswith(prefix) for prefix in _TRACKING_PREFIXES)
