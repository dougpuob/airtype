"""Instagram post extractor for public post pages.

Parses server-rendered JSON from Instagram's public post pages to extract
post text, author, media URLs, and metadata. Supports single images, videos (Reels),
and carousel posts (mixed media).
"""

from __future__ import annotations

from dataclasses import dataclass
from html.parser import HTMLParser
import html
import json
import re
import urllib.parse
import urllib.request
from typing import Any, Optional


@dataclass(frozen=True)
class CarouselItem:
    """One item in a carousel post."""
    is_video: bool
    video_url: Optional[str]
    image_url: Optional[str]


@dataclass(frozen=True)
class InstagramPost:
    """Extracted Instagram post data."""
    id: str
    url: str
    author: str
    text: str
    is_video: bool
    video_url: Optional[str]
    image_urls: tuple[str, ...]
    taken_at: int
    media_type: int
    carousel_items: tuple[CarouselItem, ...]

    def as_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "url": self.url,
            "author": self.author,
            "text": self.text,
            "is_video": self.is_video,
            "video_url": self.video_url,
            "image_urls": list(self.image_urls),
            "taken_at": self.taken_at,
            "media_type": self.media_type,
            "carousel_items": [
                {"is_video": item.is_video, "video_url": item.video_url, "image_url": item.image_url}
                for item in self.carousel_items
            ],
        }
class _JSONLDParser(HTMLParser):
    """Extract JSON-LD script content from HTML."""
    def __init__(self) -> None:
        super().__init__()
        self.in_json_ld = False
        self.json_ld_content: list[str] = []
        self._current_data = ""

    def handle_starttag(self, tag: str, attrs: list[tuple[str, Optional[str]]]) -> None:
        if tag.lower() == "script":
            for name, value in attrs:
                if name == "type" and value == "application/ld+json":
                    self.in_json_ld = True
                    self._current_data = ""
                    break

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "script" and self.in_json_ld:
            self.in_json_ld = False
            if self._current_data.strip():
                self.json_ld_content.append(self._current_data.strip())
            self._current_data = ""

    def handle_data(self, data: str) -> None:
        if self.in_json_ld:
            self._current_data += data
def _extract_json_ld(html_text: str) -> list[dict[str, Any]]:
    """Extract and parse all JSON-LD script blocks."""
    parser = _JSONLDParser()
    parser.feed(html_text)
    results: list[dict[str, Any]] = []
    for content in parser.json_ld_content:
        try:
            data = json.loads(content)
            if isinstance(data, list):
                results.extend(data)
            elif isinstance(data, dict):
                results.append(data)
        except json.JSONDecodeError:
            continue
    return results
def _extract_shared_data(html_text: str) -> list[dict[str, Any]]:
    """Extract window._sharedData and __additionalDataLoaded payloads."""
    results: list[dict[str, Any]] = []

    # Pattern 1: window._sharedData = {...};
    shared_data_pattern = re.compile(r'window\._sharedData\s*=\s*({.*?});\s*</script>', re.DOTALL)
    for match in shared_data_pattern.finditer(html_text):
        try:
            data = json.loads(match.group(1))
            results.append(data)
        except json.JSONDecodeError:
            continue

    # Pattern 2: __additionalDataLoaded('...', {...});
    additional_data_pattern = re.compile(r'__additionalDataLoaded\s*\(\s*["\'][^"\']+["\']\s*,\s*({.*?})\s*\);', re.DOTALL)
    for match in additional_data_pattern.finditer(html_text):
        try:
            data = json.loads(match.group(1))
            results.append(data)
        except json.JSONDecodeError:
            continue

    # Pattern 3: Inline JSON in script tags with "PostPage" or "media"
    script_json_pattern = re.compile(r'<script[^>]*>\s*({.*?"PostPage".*?})\s*</script>', re.DOTALL)
    for match in script_json_pattern.finditer(html_text):
        try:
            data = json.loads(match.group(1))
            results.append(data)
        except json.JSONDecodeError:
            continue

    return results
def _extract_open_graph(html_text: str) -> dict[str, str]:
    """Extract OpenGraph meta tags."""
    og: dict[str, str] = {}
    # Standard format: <meta property="og:title" content="...">
    pattern1 = re.compile(r'<meta[^>]+property=["\']([^"\']+)["\'][^>]+content=["\']([^"\']+)["\']', re.IGNORECASE)
    # Alternate format: <meta content="..." property="og:title">
    pattern2 = re.compile(r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+property=["\']([^"\']+)["\']', re.IGNORECASE)
    # Twitter cards
    pattern3 = re.compile(r'<meta[^>]+name=["\']([^"\']+)["\'][^>]+content=["\']([^"\']+)["\']', re.IGNORECASE)
    pattern4 = re.compile(r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+name=["\']([^"\']+)["\']', re.IGNORECASE)

    for pattern in (pattern1, pattern2):
        for match in pattern.finditer(html_text):
            key = match.group(1).lower()
            value = html.unescape(match.group(2)).strip()
            if key.startswith(("og:", "twitter:")) and value:
                if key not in og:
                    og[key] = value

    for pattern in (pattern3, pattern4):
        for match in pattern.finditer(html_text):
            key = match.group(1).lower()
            value = html.unescape(match.group(2)).strip()
            if key.startswith("twitter:") and value:
                if key not in og:
                    og[key] = value

    return og
def _parse_media_node(media: dict[str, Any]) -> tuple[bool, Optional[str], list[str]]:
    """Parse a media node from Instagram's GraphQL/JSON structure.

    Returns: (is_video, video_url, image_urls)
    """
    is_video = bool(media.get("is_video") or media.get("video_url"))
    video_url: Optional[str] = None
    image_urls: list[str] = []

    # Video versions - pick highest quality
    video_versions = media.get("video_versions")
    if isinstance(video_versions, list) and video_versions:
        # First is usually highest quality
        for version in video_versions:
            if isinstance(version, dict) and version.get("url"):
                video_url = version["url"]
                break

    # Fallback to direct video_url
    if not video_url:
        video_url = media.get("video_url")

    # Image versions - pick highest quality from candidates
    image_versions = media.get("image_versions2", {}).get("candidates")
    if isinstance(image_versions, list):
        for candidate in image_versions:
            if isinstance(candidate, dict) and candidate.get("url"):
                image_urls.append(candidate["url"])
                break  # First is highest quality

    # Fallback image fields
    for key in ("image_url", "display_url", "thumbnail_url"):
        url = media.get(key)
        if url and url not in image_urls:
            image_urls.append(url)

    # Carousel media
    carousel = media.get("carousel_media")
    if isinstance(carousel, list):
        for item in carousel:
            if isinstance(item, dict):
                item_video, item_vurl, item_iurls = _parse_media_node(item)
                if item_video and item_vurl and not video_url:
                    video_url = item_vurl
                image_urls.extend(item_iurls)

    return is_video, video_url, image_urls
def _extract_post_from_media(media: dict[str, Any], url: str) -> Optional[InstagramPost]:
    """Build InstagramPost from a media node."""
    try:
        shortcode = media.get("code") or media.get("shortcode")
        if not shortcode:
            # Try to extract from URL
            parsed = urllib.parse.urlparse(url)
            path_parts = [p for p in parsed.path.split("/") if p]
            if "p" in path_parts:
                idx = path_parts.index("p")
                if idx + 1 < len(path_parts):
                    shortcode = path_parts[idx + 1]
            elif "reel" in path_parts or "reels" in path_parts:
                idx = path_parts.index("reel") if "reel" in path_parts else path_parts.index("reels")
                if idx + 1 < len(path_parts):
                    shortcode = path_parts[idx + 1]

        if not shortcode:
            return None

        is_video, video_url, image_urls = _parse_media_node(media)

        # Caption text
        caption = media.get("caption")
        text = ""
        if isinstance(caption, dict):
            text = caption.get("text", "") or ""
        elif isinstance(caption, str):
            text = caption

        # Author
        author = ""
        owner = media.get("owner") or media.get("user")
        if isinstance(owner, dict):
            author = owner.get("username") or owner.get("full_name") or ""

        # Timestamp
        taken_at = 0
        for key in ("taken_at", "taken_at_timestamp", "date", "created_time"):
            val = media.get(key)
            if isinstance(val, (int, float)):
                taken_at = int(val)
                break
            if isinstance(val, str) and val.isdigit():
                taken_at = int(val)
                break

        media_type = int(media.get("media_type", 1))
        if is_video:
            media_type = 2

        # Carousel items
        carousel_items: list[CarouselItem] = []
        carousel = media.get("carousel_media")
        if isinstance(carousel, list):
            for item in carousel:
                if isinstance(item, dict):
                    item_video, item_vurl, item_iurls = _parse_media_node(item)
                    carousel_items.append(CarouselItem(
                        is_video=item_video,
                        video_url=item_vurl,
                        image_url=item_iurls[0] if item_iurls else None,
                    ))

        return InstagramPost(
            id=shortcode,
            url=url,
            author=author,
            text=text.strip(),
            is_video=is_video,
            video_url=video_url,
            image_urls=tuple(dict.fromkeys(image_urls)),  # dedupe preserving order
            taken_at=taken_at,
            media_type=media_type,
            carousel_items=tuple(carousel_items),
        )
    except Exception:
        return None
def _try_json_ld(html_text: str, url: str) -> Optional[InstagramPost]:
    """Strategy 1: Parse JSON-LD structured data."""
    for data in _extract_json_ld(html_text):
        # JSON-LD for SocialMediaPosting or VideoObject
        if isinstance(data, dict):
            graph = data.get("@graph")
            items = graph if isinstance(graph, list) else [data]
            for item in items:
                if not isinstance(item, dict):
                    continue
                item_type = item.get("@type", "")
                if item_type in ("SocialMediaPosting", "VideoObject", "ImageObject", "Post"):
                    # Try to extract media from associatedMedia or video
                    media_url = item.get("associatedMedia") or item.get("video") or item.get("contentUrl")
                    if isinstance(media_url, list):
                        media_url = media_url[0] if media_url else None

                    caption = item.get("caption") or item.get("description") or ""
                    if isinstance(caption, dict):
                        caption = caption.get("text", "") or ""

                    author = ""
                    author_obj = item.get("author")
                    if isinstance(author_obj, dict):
                        author = author_obj.get("name") or author_obj.get("alternateName") or ""

                    return InstagramPost(
                        id=item.get("identifier", "") or "",
                        url=url,
                        author=author,
                        text=caption.strip() if isinstance(caption, str) else "",
                        is_video=item_type == "VideoObject",
                        video_url=media_url if item_type == "VideoObject" else None,
                        image_urls=(item.get("image", []) if isinstance(item.get("image"), list)
                                   else [item.get("image")] if item.get("image") else ()),
                        taken_at=0,
                        media_type=2 if item_type == "VideoObject" else 1,
                        carousel_items=(),
                    )
    return None
def _try_shared_data(html_text: str, url: str) -> Optional[InstagramPost]:
    """Strategy 2: Parse window._sharedData / __additionalDataLoaded."""
    for data in _extract_shared_data(html_text):
        # Navigate to PostPage -> graphql -> shortcode_media
        entry_data = data.get("entry_data")
        if isinstance(entry_data, dict):
            post_pages = entry_data.get("PostPage")
            if isinstance(post_pages, list):
                for page in post_pages:
                    if isinstance(page, dict):
                        graphql = page.get("graphql")
                        if isinstance(graphql, dict):
                            media = graphql.get("shortcode_media")
                            if isinstance(media, dict):
                                return _extract_post_from_media(media, url)

        # Alternative: direct media in data
        media = data.get("media") or data.get("shortcode_media")
        if isinstance(media, dict):
            return _extract_post_from_media(media, url)

        # Check for items array (newer format)
        items = data.get("items")
        if isinstance(items, list):
            for item in items:
                if isinstance(item, dict):
                    result = _extract_post_from_media(item, url)
                    if result:
                        return result

    return None
def _try_open_graph(html_text: str, url: str) -> Optional[InstagramPost]:
    """Strategy 3: Fallback to OpenGraph meta tags."""
    og = _extract_open_graph(html_text)
    if not og:
        return None

    # Extract shortcode from URL
    shortcode = ""
    parsed = urllib.parse.urlparse(url)
    path_parts = [p for p in parsed.path.split("/") if p]
    for key in ("p", "reel", "reels", "tv"):
        if key in path_parts:
            idx = path_parts.index(key)
            if idx + 1 < len(path_parts):
                shortcode = path_parts[idx + 1]
                break

    text = og.get("og:description") or og.get("twitter:description") or ""
    author = ""
    # og:title often contains "username on Instagram: ..."
    title = og.get("og:title", "")
    match = re.match(r"^([^@\s]+)\s+on\s+Instagram", title)
    if match:
        author = match.group(1)

    image_url = og.get("og:image") or og.get("og:image:url") or og.get("og:image:secure_url") or ""
    video_url = og.get("og:video") or og.get("og:video:url") or og.get("og:video:secure_url") or ""
    is_video = bool(video_url)

    return InstagramPost(
        id=shortcode,
        url=url,
        author=author,
        text=text.strip(),
        is_video=is_video,
        video_url=video_url if is_video else None,
        image_urls=(image_url,) if image_url else (),
        taken_at=0,
        media_type=2 if is_video else 1,
        carousel_items=(),
    )
class InstagramPostExtractor:
    """Extract Instagram post data from public post URLs."""

    def __init__(self, timeout: int = 15) -> None:
        self.timeout = timeout
        self._user_agent = (
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        )

    def extract(self, url: str, cookie_header: str = "") -> InstagramPost:
        """Fetch and parse an Instagram post page.

        Args:
            url: Instagram post URL (e.g., https://www.instagram.com/p/ABC123/)
            cookie_header: Optional Cookie header for authenticated requests

        Returns:
            InstagramPost with extracted data

        Raises:
            ValueError: If URL is invalid or not an Instagram post
            RuntimeError: If page cannot be fetched or parsed
        """
        parsed = urllib.parse.urlparse(url)
        if parsed.netloc.lower() not in ("instagram.com", "www.instagram.com"):
            raise ValueError("URL must be an Instagram post URL")

        html_text = self._fetch_page(url, cookie_header)

        # Try strategies in order of reliability
        for strategy in (_try_json_ld, _try_shared_data, _try_open_graph):
            result = strategy(html_text, url)
            if result and (result.text or result.image_urls or result.video_url):
                return result

        # Last resort: return minimal post from OG
        og_result = _try_open_graph(html_text, url)
        if og_result:
            return og_result

        raise RuntimeError("Could not extract post data from Instagram page")

    def _fetch_page(self, url: str, cookie_header: str) -> str:
        """Fetch the HTML page with appropriate headers."""
        headers = {
            "User-Agent": self._user_agent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        }
        if cookie_header:
            headers["Cookie"] = cookie_header

        request = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                content_type = response.headers.get("Content-Type", "")
                if "text/html" not in content_type:
                    raise RuntimeError(f"Unexpected content type: {content_type}")
                return response.read(5 * 1024 * 1024).decode("utf-8", errors="replace")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise RuntimeError("Post not found (404)") from e
            if e.code in (403, 429):
                raise RuntimeError("Access denied - post may be private or rate limited") from e
            raise RuntimeError(f"HTTP {e.code}: {e.reason}") from e
        except urllib.error.URLError as e:
            raise RuntimeError(f"Network error: {e.reason}") from e


# Convenience function for backward compatibility
def extract_instagram_post(url: str, cookie_header: str = "") -> InstagramPost:
    """Extract Instagram post data from a public URL."""
    return InstagramPostExtractor().extract(url, cookie_header)