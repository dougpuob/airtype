"""Resolve an Apple Podcasts episode page into show notes and an audio URL.

The Apple page is not the media. Episode audio lives on the publisher
enclosure (for example a SoundOn mp3). YouTube links that appear on the
Apple page are left alone.
"""

from __future__ import annotations

from dataclasses import dataclass
import html
import json
import re
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree
from typing import Callable, Optional


class AppleEpisodeError(RuntimeError):
    """The Apple Podcasts URL could not be turned into notes plus an audio file."""


@dataclass(frozen=True)
class AppleEpisode:
    """Show notes and the enclosure that should be transcribed."""

    page_url: str
    show_id: str
    episode_id: str
    title: str
    description: str
    audio_url: str


LOOKUP_LIMIT = 200
USER_AGENT = "AirType/1.0"
SHOW_ID_PATTERN = re.compile(r"/id(\d+)")
SLUG_PATTERN = re.compile(r"/podcast/([^/]+)/id\d+", re.IGNORECASE)
EPISODE_ID_IN_LINK = re.compile(r"[?&]i=(\d+)")


def is_apple_podcast_url(url: str) -> bool:
    """Whether the URL is on podcasts.apple.com."""
    return _host(url).endswith("podcasts.apple.com")


def parse_episode_url(url: str) -> Optional[tuple[str, str, str]]:
    """``(show_id, episode_id, slug)`` for an episode page, or None.

    The slug is the path segment before ``id{showId}`` (``ep706``). A show
    page without ``?i=`` is not an episode.
    """
    if not is_apple_podcast_url(url):
        return None
    parsed = urllib.parse.urlparse(url)
    show_match = SHOW_ID_PATTERN.search(parsed.path or "")
    episode_id = ""
    for key, value in urllib.parse.parse_qsl(parsed.query, keep_blank_values=False):
        if key == "i" and value.isdigit():
            episode_id = value
            break
    if not show_match or not episode_id:
        return None
    slug_match = SLUG_PATTERN.search(parsed.path or "")
    slug = urllib.parse.unquote(slug_match.group(1)).strip() if slug_match else ""
    return show_match.group(1), episode_id, slug


def original_content(description: str, transcript: str) -> str:
    """Episode notes above the transcript, separated by a blank line."""
    notes = (description or "").strip()
    spoken = (transcript or "").strip()
    if notes and spoken:
        return f"{notes}\n\n{spoken}"
    return notes or spoken


def resolve_episode(
    url: str,
    *,
    lookup: Optional[Callable[[str], dict]] = None,
    fetch_feed: Optional[Callable[[str], str]] = None,
) -> AppleEpisode:
    """Show notes and enclosure URL for one Apple Podcasts episode page.

    Recent episodes come from the iTunes lookup window. Older episodes fall
    back to the show RSS feed, matched by guid and then by the URL slug.
    """
    parsed = parse_episode_url(url)
    if not parsed:
        raise AppleEpisodeError("This is not an Apple Podcasts episode URL.")
    show_id, episode_id, slug = parsed
    payload = (lookup or _lookup_show)(show_id)
    results = payload.get("results") if isinstance(payload, dict) else None
    if not isinstance(results, list):
        raise AppleEpisodeError("iTunes did not return show data for this episode.")

    feed_url = ""
    for item in results:
        if not isinstance(item, dict):
            continue
        if _same_id(item.get("trackId"), episode_id) and item.get("kind") == "podcast-episode":
            episode = _episode_from_lookup(url, show_id, episode_id, item)
            if episode:
                return episode
        if not feed_url and isinstance(item.get("feedUrl"), str):
            feed_url = item["feedUrl"].strip()

    if not feed_url:
        raise AppleEpisodeError("Could not find audio or show notes for this episode.")
    feed_xml = (fetch_feed or _fetch_text)(feed_url)
    episode = _episode_from_feed(url, show_id, episode_id, slug, feed_xml)
    if not episode:
        raise AppleEpisodeError("Could not find audio or show notes for this episode.")
    return episode


def _episode_from_lookup(url: str, show_id: str, episode_id: str, item: dict) -> Optional[AppleEpisode]:
    audio_url = str(item.get("episodeUrl") or "").strip()
    description = _plain_text(str(item.get("description") or ""))
    title = str(item.get("trackName") or "").strip()
    if not audio_url or not description:
        return None
    return AppleEpisode(
        page_url=url,
        show_id=show_id,
        episode_id=episode_id,
        title=title or episode_id,
        description=description,
        audio_url=audio_url,
    )


def _episode_from_feed(
    url: str,
    show_id: str,
    episode_id: str,
    slug: str,
    feed_xml: str,
) -> Optional[AppleEpisode]:
    try:
        root = ElementTree.fromstring(feed_xml)
    except ElementTree.ParseError:
        return None
    slug_match: Optional[AppleEpisode] = None
    for item in root.iter():
        if _local_name(item.tag) != "item":
            continue
        episode = _episode_from_item(url, show_id, episode_id, item)
        if not episode:
            continue
        if _item_matches_episode_id(item, episode_id):
            return episode
        if slug_match is None and _slug_matches_title(slug, episode.title):
            slug_match = episode
    return slug_match


def _episode_from_item(url: str, show_id: str, episode_id: str, item: ElementTree.Element) -> Optional[AppleEpisode]:
    title = ""
    descriptions: list[str] = []
    audio_url = ""
    for child in list(item):
        name = _local_name(child.tag)
        text = _plain_text("".join(child.itertext()))
        if name == "title" and text:
            title = text
        elif name in {"description", "encoded", "summary"} and text:
            descriptions.append(text)
        elif name == "enclosure":
            audio_url = str(child.attrib.get("url") or "").strip()
    description = max(descriptions, key=len) if descriptions else ""
    if not audio_url or not description:
        return None
    return AppleEpisode(
        page_url=url,
        show_id=show_id,
        episode_id=episode_id,
        title=title or episode_id,
        description=description,
        audio_url=audio_url,
    )


def _item_matches_episode_id(item: ElementTree.Element, episode_id: str) -> bool:
    for child in list(item):
        name = _local_name(child.tag)
        text = "".join(child.itertext()).strip()
        if name == "guid" and text == episode_id:
            return True
        if name in {"guid", "link"} and EPISODE_ID_IN_LINK.search(text):
            found = EPISODE_ID_IN_LINK.search(text)
            if found and found.group(1) == episode_id:
                return True
    return False


def _slug_matches_title(slug: str, title: str) -> bool:
    slug_norm = re.sub(r"[^a-z0-9\u4e00-\u9fff]+", "", slug.lower())
    title_norm = re.sub(r"[^a-z0-9\u4e00-\u9fff]+", "", title.lower())
    if len(slug_norm) < 3:
        return False
    return slug_norm in title_norm


def _lookup_show(show_id: str) -> dict:
    query = urllib.parse.urlencode({
        "id": show_id,
        "entity": "podcastEpisode",
        "limit": str(LOOKUP_LIMIT),
    })
    raw = _fetch_text(f"https://itunes.apple.com/lookup?{query}")
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as error:
        raise AppleEpisodeError("iTunes did not return show data for this episode.") from error
    if not isinstance(payload, dict):
        raise AppleEpisodeError("iTunes did not return show data for this episode.")
    return payload


def _fetch_text(url: str) -> str:
    request = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "Accept": "application/json, application/xml, text/xml, */*",
    })
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read().decode("utf-8", errors="replace")
    except Exception as error:
        raise AppleEpisodeError(f"Could not load show data: {error}") from error


def _plain_text(value: str) -> str:
    text = html.unescape(value or "")
    text = re.sub(r"<\s*br\s*/?\s*>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"</\s*p\s*>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return text.strip()


def _same_id(value: object, episode_id: str) -> bool:
    return str(value or "").strip() == episode_id


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _host(url: str) -> str:
    try:
        parsed = urllib.parse.urlparse(url)
    except ValueError:
        return ""
    return (parsed.hostname or "").lower()
