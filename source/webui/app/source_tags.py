"""Deterministic Obsidian tags derived from a note's source URLs.

Every note gets the short site name of each source URL (``kimo`` for
``www.kimo.com.tw``, ``facebook`` for ``m.facebook.com``).

Social posts (Threads, Instagram, Facebook, LinkedIn) also get the platform
and the author's bare user name::

    facebook
    dougpuob

An all-digit id (a Facebook author without a user name in the URL) is not a
valid Obsidian tag, so it is left out.

These come from the post URL and the capture payload, not from the LLM, so
the same post always gets the same tags.
"""

from __future__ import annotations

import re
from typing import Any, Iterable, Mapping, Optional
from urllib.parse import parse_qs, unquote, urlparse

_PLATFORM_HOSTS = (
    ("threads", ("threads.com", "threads.net")),
    ("instagram", ("instagram.com",)),
    ("facebook", ("facebook.com", "fb.watch", "fb.com", "fb.me")),
    ("linkedin", ("linkedin.com", "lnkd.in")),
)
_DROPPED_HOST_PREFIXES = ("www.", "m.")
_TAG_UNSAFE = re.compile(r"[^\w-]+", re.UNICODE)

_THREADS_POST = re.compile(r"^/@([^/]+)/post/([A-Za-z0-9_-]+)", re.IGNORECASE)
_THREADS_SHORT = re.compile(r"^/t/([A-Za-z0-9_-]+)", re.IGNORECASE)
_INSTAGRAM_KINDS = {"p", "reel", "reels", "tv"}
_LINKEDIN_URN = re.compile(r"urn:li:(?:activity|share|ugcPost):(\d{10,})", re.IGNORECASE)
_LINKEDIN_SLUG = re.compile(r"^/posts/([^/]+?)_[^/]*-(?:activity|share|ugcPost)-(\d{10,})(?=-|/|$)", re.IGNORECASE)
_LINKEDIN_PROFILE = re.compile(r"^/(?:in|company)/([^/?#]+)", re.IGNORECASE)
# Facebook path segments that are not a user name.
_FACEBOOK_RESERVED = {
    "groups", "share", "reel", "reels", "watch", "photo", "photos", "story.php",
    "permalink.php", "photo.php", "video.php", "profile.php", "events", "pages", "hashtag",
}
_FACEBOOK_QUERY_IDS = {"/permalink.php": "story_fbid", "/story.php": "story_fbid", "/photo.php": "fbid", "/photo": "fbid", "/video.php": "v", "/watch": "v"}
_NUMERIC = re.compile(r"^\d{6,}$")


def _host(url: str) -> str:
    try:
        parsed = urlparse(str(url or "").strip())
    except ValueError:
        return ""
    if parsed.scheme not in {"http", "https"}:
        return ""
    host = (parsed.hostname or "").lower().strip(".")
    for prefix in _DROPPED_HOST_PREFIXES:
        if host.startswith(prefix) and host.count(".") > 1:
            host = host[len(prefix):]
    return host


def _host_is(host: str, domain: str) -> bool:
    return host == domain or host.endswith("." + domain)


def tag_value(value: Any) -> str:
    """``value`` as one Obsidian tag segment: letters, digits, ``_`` and ``-`` only."""
    return _TAG_UNSAFE.sub("-", str(value or "").strip().lstrip("@")).strip("-")


def platform_for(url: str) -> str:
    host = _host(url)
    for name, domains in _PLATFORM_HOSTS:
        if any(_host_is(host, domain) for domain in domains):
            return name
    return ""


def domain_tags(urls: Iterable[str]) -> list[str]:
    """Short site name of each URL (``www.kimo.com.tw`` -> ``kimo``)."""
    tags: list[str] = []
    for value in urls:
        host = _host(value)
        if not host or host.endswith(".ts.net"):
            continue
        tag = tag_value(host.split(".")[0])
        if tag and tag not in tags:
            tags.append(tag)
    return tags


def _threads_identity(path: str) -> tuple[str, str]:
    match = _THREADS_POST.match(path)
    if match:
        return match.group(2), match.group(1)
    match = _THREADS_SHORT.match(path)
    return (match.group(1), "") if match else ("", "")


def _instagram_identity(path: str) -> tuple[str, str]:
    parts = [part for part in path.split("/") if part]
    for index, part in enumerate(parts[:2]):
        if part.lower() in _INSTAGRAM_KINDS and index + 1 < len(parts):
            user = parts[0] if index == 1 else ""
            return parts[index + 1], user
    return "", ""


def _facebook_identity(path: str, query: str) -> tuple[str, str]:
    params = parse_qs(query)
    key = _FACEBOOK_QUERY_IDS.get(path.rstrip("/").lower())
    if key:
        post_id = (params.get(key) or [""])[0]
        user = (params.get("id") or [""])[0] if key == "story_fbid" else ""
        return post_id, user
    parts = [part for part in path.split("/") if part]
    if len(parts) >= 3 and parts[0].lower() == "groups" and parts[2].lower() in {"posts", "permalink"}:
        return (parts[3] if len(parts) > 3 else ""), ""
    if len(parts) >= 2 and parts[0].lower() in {"reel", "reels"}:
        return parts[1], ""
    if len(parts) >= 3 and parts[1].lower() in {"posts", "videos"} and parts[0].lower() not in _FACEBOOK_RESERVED:
        # /<user>/posts/<id> or /<user>/posts/<text slug>/<id>/
        return parts[-1], parts[0]
    return "", ""


def _linkedin_identity(path: str) -> tuple[str, str]:
    match = _LINKEDIN_SLUG.match(path)
    if match:
        return match.group(2), match.group(1)
    match = _LINKEDIN_URN.search(path)
    return (match.group(1), "") if match else ("", "")


def url_identity(url: str) -> dict[str, str]:
    """``{"platform", "post_id", "user_id"}`` read from one social post URL ("" when unknown)."""
    platform = platform_for(url)
    post_id = user_id = ""
    if platform:
        parsed = urlparse(str(url).strip())
        path = unquote(parsed.path or "")
        if platform == "threads":
            post_id, user_id = _threads_identity(path)
        elif platform == "instagram":
            post_id, user_id = _instagram_identity(path)
        elif platform == "facebook":
            post_id, user_id = _facebook_identity(path, parsed.query)
        elif platform == "linkedin":
            post_id, user_id = _linkedin_identity(path)
    return {"platform": platform, "post_id": post_id, "user_id": user_id}


def post_identity(urls: Iterable[str], payload: Optional[Mapping[str, Any]] = None) -> dict[str, str]:
    """Platform, post id and author of a captured social post.

    The source URLs are read in order (the post a share link resolved to fills
    in what the short link lacks). The capture payload fills the gaps:
    ``post_id``/``author_id`` (Facebook's numeric ids), ``author_url``
    (LinkedIn profile) and ``author`` (the handle, for Threads and Instagram).
    """
    payload = payload or {}
    identity = {"platform": "", "post_id": "", "user_id": ""}
    for url in urls:
        found = url_identity(url)
        if not found["platform"]:
            continue
        if identity["platform"] and found["platform"] != identity["platform"]:
            continue
        for key, value in found.items():
            identity[key] = identity[key] or value
    platform = identity["platform"]
    if not platform:
        return identity
    if platform == "facebook":
        # The story's numeric post id is stable; the pfbid in some URLs is not.
        story_id = str(payload.get("post_id") or "").strip()
        if _NUMERIC.match(story_id):
            identity["post_id"] = story_id
        identity["user_id"] = identity["user_id"] or str(payload.get("author_id") or "").strip()
    elif platform == "linkedin" and not identity["user_id"]:
        profile = _LINKEDIN_PROFILE.match(unquote(urlparse(str(payload.get("author_url") or "")).path or ""))
        identity["user_id"] = profile.group(1) if profile else ""
    elif platform in {"threads", "instagram"} and not identity["user_id"]:
        author = str(payload.get("author") or "").strip()
        identity["user_id"] = author if re.fullmatch(r"@?[A-Za-z0-9._]+", author) else ""
    return identity


def post_tags(urls: Iterable[str], payload: Optional[Mapping[str, Any]] = None) -> list[str]:
    """``[platform, <user name>]`` for a social post (no user tag when the author is unknown)."""
    identity = post_identity(list(urls), payload)
    platform = identity["platform"]
    if not platform:
        return []
    tags = [platform]
    user_id = tag_value(identity["user_id"])
    if user_id and not user_id.isdigit():
        tags.append(user_id)
    return tags
