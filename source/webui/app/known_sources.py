"""Known sources that AirType extracts with dedicated pipelines.

A URL belonging to one of these sources is routed to its own feature
(Capture Post for Threads, V-to-Text for media platforms and raw media
files) and is excluded from the generic web-article pipeline backed by
md.genedai.me. Every entry maps to a pipeline that already exists, so
this list is a code constant rather than user configuration.

Host matching is suffix-based on the hostname: ``www.youtube.com``
matches ``youtube.com``, while lookalike domains such as
``notyoutube.com`` never match.
"""

from __future__ import annotations

from dataclasses import dataclass
import urllib.parse
from typing import Any, Optional


@dataclass(frozen=True)
class KnownSource:
    """One host family plus the pipeline that knows how to extract it."""

    host: str
    pipeline: str


# Pipeline ids:
#   "capture-post" — Threads chain collection (app/post_weaver.py)
#   "v-to-text"    — yt-dlp media download + whisper transcription
KNOWN_SOURCE_HOSTS: tuple[KnownSource, ...] = (
    KnownSource(host="threads.com", pipeline="capture-post"),
    KnownSource(host="threads.net", pipeline="capture-post"),
    KnownSource(host="youtube.com", pipeline="v-to-text"),
    KnownSource(host="youtu.be", pipeline="v-to-text"),
    KnownSource(host="bilibili.com", pipeline="v-to-text"),
    KnownSource(host="b23.tv", pipeline="v-to-text"),
    KnownSource(host="instagram.com", pipeline="v-to-text"),
    KnownSource(host="tiktok.com", pipeline="v-to-text"),
)

# Any path containing this marker is a known video source (YouTube Shorts)
# regardless of the host.
SHORTS_PATH_MARKER = "/shorts/"

# Direct media file links skip source detection and go straight to
# V-to-Text, which downloads the file and transcribes it.
MEDIA_FILE_EXTENSIONS: tuple[str, ...] = (
    ".aac", ".aif", ".aiff", ".flac", ".m4a", ".m4v", ".mkv", ".mov",
    ".mp3", ".mp4", ".mpeg", ".mpg", ".ogg", ".opus", ".wav", ".webm",
)

PIPELINE_LABELS: dict[str, str] = {
    "capture-post": "Capture Post",
    "v-to-text": "V-to-Text",
    "web-article": "Web Article",
}

WEB_ARTICLE_PIPELINE = "web-article"


def _url_host(url: str) -> str:
    """Lowercased hostname without port, or "" when the URL cannot be parsed."""
    try:
        parsed = urllib.parse.urlparse(url)
    except ValueError:
        return ""
    return (parsed.netloc or "").lower().split(":", 1)[0].strip(".")


def _url_path(url: str) -> str:
    """Lowercased path, or "" when the URL cannot be parsed."""
    try:
        parsed = urllib.parse.urlparse(url)
    except ValueError:
        return ""
    return (parsed.path or "").lower()


def _host_matches(host: str, known_host: str) -> bool:
    """Exact match or a proper ``.``-separated subdomain of the known host."""
    return host == known_host or host.endswith("." + known_host)


def match_known_source(url: str) -> Optional[KnownSource]:
    """The known source a URL belongs to, or None when it is not one."""
    host = _url_host(url)
    if not host:
        return None
    for source in KNOWN_SOURCE_HOSTS:
        if _host_matches(host, source.host):
            return source
    return None


def is_shorts_url(url: str) -> bool:
    """Whether the URL points at a YouTube Shorts-style path."""
    return SHORTS_PATH_MARKER in _url_path(url)


def has_media_file_extension(url: str) -> bool:
    """Whether the URL path ends with a directly transcribable media file."""
    path = _url_path(url)
    return any(path.endswith(extension) for extension in MEDIA_FILE_EXTENSIONS)


def route_for_url(url: str) -> str:
    """The pipeline that should handle this URL.

    Returns the owning pipeline id (``capture-post`` or ``v-to-text``) for
    known sources, and ``web-article`` for everything else. The web-article
    pipeline is the md.genedai.me backed generic extractor for pages that
    have no dedicated tool.
    """
    source = match_known_source(url)
    if source:
        return source.pipeline
    if is_shorts_url(url) or has_media_file_extension(url):
        return "v-to-text"
    return WEB_ARTICLE_PIPELINE


def known_source_hint(url: str) -> str:
    """A short user-facing hint when a known-source URL reaches the wrong page."""
    source = match_known_source(url)
    if source:
        label = PIPELINE_LABELS.get(source.pipeline, source.pipeline)
        return f"此連結屬於{label}支援的來源（{source.host}），請改用{label}。"
    if is_shorts_url(url) or has_media_file_extension(url):
        return "此連結是媒體檔或影片連結，請改用 V-to-Text。"
    return ""


def known_sources_payload() -> dict[str, Any]:
    """Serializable summary for GET /api/web-article/known-sources."""
    return {
        "sources": [
            {
                "host": source.host,
                "pipeline": source.pipeline,
                "label": PIPELINE_LABELS.get(source.pipeline, source.pipeline),
            }
            for source in KNOWN_SOURCE_HOSTS
        ],
        "shorts_path_marker": SHORTS_PATH_MARKER,
        "media_file_extensions": list(MEDIA_FILE_EXTENSIONS),
        "web_article_pipeline": WEB_ARTICLE_PIPELINE,
    }