"""Generic web-article pipeline backed by md.genedai.me and Immich.

Flow:
  1. Fetch the article as Markdown (``GET https://md.genedai.me/<url>?raw=true``).
  2. Collect the image URLs embedded in the Markdown.
  3. Download and upload every image to Immich under the dedicated account,
     tagging each asset with the note GUID so the note owns its images.
  4. Create one passwordless shared link and rewrite image links so Obsidian
     renders the images from Immich.

Images that fail at any step keep their original URL, and the job reports a
warning instead of failing the whole note.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import mimetypes
import re
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any, Callable, Optional

from . import known_sources
from .immich import IMAGE_EXTENSION_BY_CONTENT_TYPE, ImmichClient, ImmichError

MD_GENEDAI_HOST = "md.genedai.me"
USER_AGENT = "Mozilla/5.0 (compatible; AirType WebArticle/1.0)"

# Hosts the generic pipeline must never fetch: the conversion service itself
# and local/private network addresses. (User-visible known sources live in
# known_sources; this is the extra safety boundary for the fallback route.)
BLOCKED_HOSTS = {MD_GENEDAI_HOST, "localhost"}
BLOCKED_HOST_SUFFIXES = (".local", ".localhost")
BLOCKED_HOST_PATTERN = re.compile(
    r"^(127\.|10\.|192\.168\.|169\.254\.|0\.|172\.(1[6-9]|2\d|3[01])\.|::1$)"
)

IMAGE_MARKDOWN_PATTERN = re.compile(r"!\[[^\]]*\]\(\s*(<[^)]*>|[^)\s]+)")
IMAGE_HTML_PATTERN = re.compile(r"<img\b[^>]*?\bsrc=[\"']([^\"']+)[\"']", re.IGNORECASE)
HEADING_PATTERN = re.compile(r"^#{1,3}\s+(.+?)\s*$")


class KnownSourceError(ValueError):
    """Raised when a known-source URL is submitted to the web-article pipeline."""


def blocked_host_reason(url: str) -> str:
    """A user-facing reason when the host must not be fetched, or ""."""
    try:
        parsed = urllib.parse.urlparse(url)
    except ValueError:
        return "無法解析這個網址。"
    host = (parsed.hostname or "").lower()
    if not host:
        return "網址沒有可解析的主機名稱。"
    if host in BLOCKED_HOSTS:
        return f"{host} 不能透過網頁文章管線抓取。"
    if host.endswith(BLOCKED_HOST_SUFFIXES) or BLOCKED_HOST_PATTERN.match(host):
        return f"私有或本機位址（{host}）不能透過網頁文章管線抓取。"
    return ""


def extract_image_urls(markdown: str, base_url: str = "") -> list[str]:
    """Ordered, de-duplicated absolute image URLs inside a Markdown document.

    ``data:`` URIs and non-http(s) links are skipped; relative paths are
    resolved against ``base_url`` when it is provided.
    """
    candidates: list[str] = []
    for match in IMAGE_MARKDOWN_PATTERN.finditer(markdown or ""):
        candidates.append(match.group(1).strip().strip("<>"))
    for match in IMAGE_HTML_PATTERN.finditer(markdown or ""):
        candidates.append(match.group(1).strip())

    urls: list[str] = []
    seen: set[str] = set()
    for candidate in candidates:
        if not candidate or candidate.lower().startswith("data:"):
            continue
        resolved = urllib.parse.urljoin(base_url, candidate) if base_url else candidate
        resolved = resolved.strip()
        if not resolved.lower().startswith(("http://", "https://")):
            continue
        if resolved in seen:
            continue
        seen.add(resolved)
        urls.append(resolved)
    return urls


def rewrite_image_links(markdown: str, mapping: dict[str, str]) -> str:
    """Replace original image URLs with their Immich embedded URLs."""
    rewritten = markdown or ""
    for source, replacement in (mapping or {}).items():
        if source and replacement and source != replacement:
            rewritten = rewritten.replace(source, replacement)
    return rewritten


def extract_title(markdown: str, fallback: str = "") -> str:
    """The first Markdown heading, or ``fallback`` when there is none."""
    for line in (markdown or "").splitlines():
        match = HEADING_PATTERN.match(line.strip())
        if match and match.group(1).strip():
            return match.group(1).strip()
    return fallback


# Below this many non-heading body characters the article likely came back
# with just its title (anonymous-tier pages without the browser engine).
SHORT_BODY_CHARS = 200


def article_body_chars(markdown: str) -> int:
    """Character count of non-heading, non-blank Markdown body lines."""
    count = 0
    for line in (markdown or "").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("---"):
            continue
        count += len(stripped)
    return count


def _curl_requests():
    from curl_cffi import requests as curl_requests

    return curl_requests


def fetch_markdown(url: str, *, api_key: str = "", timeout_seconds: int = 60) -> str:
    """Fetch ``url`` through md.genedai.me as raw Markdown.

    ``?raw=true`` keeps the response clean of the reading-view HTML, and an
    optional ``Authorization: Bearer <key>`` unlocks browser/firecrawl/jina
    engines on key-carrying tiers. The fragment is dropped first so
    ``raw=true`` always lands in the real query string.
    """
    clean_url = url.split("#", 1)[0]
    separator = "&" if "?" in clean_url else "?"
    target = f"https://{MD_GENEDAI_HOST}/{clean_url}{separator}raw=true"
    headers = {
        "User-Agent": USER_AGENT,
        "Accept": "text/markdown",
    }
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    try:
        curl_requests = _curl_requests()
        response = curl_requests.get(
            target, headers=headers, timeout=timeout_seconds, allow_redirects=True
        )
        if response.status_code >= 400:
            raise RuntimeError(f"md.genedai.me 回應 {response.status_code}：{response.text[:200]}")
        markdown_text = response.text
        _raise_if_html(markdown_text)
        return markdown_text
    except ImportError:
        try:
            request = urllib.request.Request(target, headers=headers)
            with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
                markdown_text = response.read().decode("utf-8", errors="replace")
                _raise_if_html(markdown_text)
                return markdown_text
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"md.genedai.me 回應 {error.code}：{error.reason}") from error
        except urllib.error.URLError as error:
            raise RuntimeError(f"無法連上 md.genedai.me：{error.reason}") from error
        except RuntimeError:
            raise
        except Exception as error:
            raise RuntimeError(f"抓取文章失敗：{error}") from error
    except RuntimeError:
        raise
    except Exception as error:
        raise RuntimeError(f"抓取文章失敗：{error}") from error


def _raise_if_html(text: str) -> None:
    """Reject HTML reading-view responses with actionable guidance."""
    stripped = (text or "").lstrip()[:512].lower()
    if stripped.startswith(("<!doctype html", "<html", "<head", "<body")):
        raise RuntimeError(
            "md.genedai.me 回傳的是 HTML 頁面而不是 Markdown；"
            "這個網站可能需要 md.genedai.me API key 的瀏覽器引擎才能轉換。"
        )


def _read_capped(chunks, max_bytes: int, url: str) -> bytes:
    buffer = bytearray()
    for chunk in chunks:
        if not chunk:
            break
        buffer.extend(chunk)
        if len(buffer) > max_bytes:
            raise RuntimeError(
                f"圖片超過大小上限（{max_bytes // (1024 * 1024)}MB）：{url}"
            )
    if not buffer:
        raise RuntimeError(f"圖片內容是空的：{url}")
    return bytes(buffer)


def download_image(
    url: str,
    *,
    article_url: str = "",
    timeout_seconds: int = 60,
    max_bytes: int = 20 * 1024 * 1024,
) -> tuple[bytes, str]:
    """Download one image; returns ``(data, image_content_type)``.

    The article URL is sent as ``Referer`` so hotlink-protected CDNs keep
    serving the image. The response must be an image (or at least guessable
    as one from the URL); anything else is an error.
    """
    headers = {
        "User-Agent": USER_AGENT,
        "Accept": "image/*,*/*;q=0.8",
        "Referer": article_url or url,
    }
    try:
        curl_requests = _curl_requests()
        response = curl_requests.get(
            url, headers=headers, timeout=timeout_seconds, stream=True
        )
        if response.status_code >= 400:
            raise RuntimeError(f"圖片伺服器回應 {response.status_code}：{url}")
        content_type = _clean_content_type(response.headers.get("Content-Type"))
        data = _read_capped(response.iter_content(chunk_size=64 * 1024), max_bytes, url)
    except ImportError:
        try:
            request = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
                content_type = _clean_content_type(response.headers.get("Content-Type"))
                data = _read_capped(iter(lambda: response.read(64 * 1024), b""), max_bytes, url)
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"圖片下載失敗（HTTP {error.code}）：{url}") from error
        except RuntimeError:
            raise
        except Exception as error:
            raise RuntimeError(f"圖片下載失敗：{url}（{error}）") from error
    except RuntimeError:
        raise
    except Exception as error:
        raise RuntimeError(f"圖片下載失敗：{url}（{error}）") from error

    content_type = _ensure_image_content_type(url, content_type)
    return data, content_type


def _clean_content_type(value: Optional[str]) -> str:
    return (value or "").split(";")[0].strip().lower()


def _ensure_image_content_type(url: str, content_type: str) -> str:
    if content_type.startswith("image/"):
        return content_type
    guessed = mimetypes.guess_type(url)[0] or ""
    if guessed.startswith("image/"):
        return guessed
    raise RuntimeError(f"連結不是圖片（{content_type or '未知類型'}）：{url}")


def image_filename(index: int, content_type: str) -> str:
    extension = (
        IMAGE_EXTENSION_BY_CONTENT_TYPE.get(content_type)
        or mimetypes.guess_extension(content_type)
        or ".img"
    )
    return f"image-{index}{extension}"


def _validated_note_guid(value: str) -> str:
    """The caller's note GUID normalized to canonical UUID form, or a fresh one.

    Every AirType note carries a GUID in its frontmatter and every photo of
    that note is tagged with the same GUID inside Immich, so the web-article
    job and the note-media endpoint share one validation path.
    """
    trimmed = str(value or "").strip()
    if not trimmed:
        return str(uuid.uuid4())
    try:
        return str(uuid.UUID(trimmed))
    except (ValueError, AttributeError, TypeError) as error:
        raise ValueError("GUID 必須是有效的 UUID 格式。") from error


def store_note_media(
    image_urls: list[str],
    *,
    source_url: str = "",
    guid: str = "",
    title: str = "",
    immich_server_url: str = "",
    immich_api_key: str = "",
    timeout_seconds: int = 60,
    download_max_mb: int = 20,
    create_album: bool = False,
    on_progress: Optional[Callable[[int, str], None]] = None,
) -> dict[str, Any]:
    """Download, upload, tag, and share note photos through Immich.

    This is the shared pipeline behind web-article jobs and the note-media
    endpoint: every image is downloaded, uploaded into the dedicated Immich
    account, tagged with the note GUID, and mapped to a key-gated thumbnail
    URL from one passwordless shared link. Images that fail at any step keep
    their original URL and are reported in ``warnings`` instead of failing
    the whole note.

    Returns ``{"images", "share_url", "album_id", "warnings"}`` where each
    image record is ``{"url", "asset_id", "status", "warning", "embedded_url"}``.
    """
    def progress(percent: int, message: str) -> None:
        if on_progress:
            on_progress(percent, message)

    client = ImmichClient(immich_server_url, immich_api_key, timeout_seconds=timeout_seconds)
    images: list[dict[str, Any]] = []
    warnings: list[str] = []
    if image_urls and not client.configured:
        warnings.append("尚未設定 Immich（server_url / api_key），圖片保留原始連結。")

    total = len(image_urls)
    asset_ids: list[str] = []
    for index, image_url in enumerate(image_urls):
        progress(20 + int(35 * (index / max(total, 1))), f"處理圖片 {index + 1}/{total}…")
        if not client.configured:
            break
        try:
            data, content_type = download_image(
                image_url,
                article_url=source_url,
                timeout_seconds=timeout_seconds,
                max_bytes=download_max_mb * 1024 * 1024,
            )
            uploaded = client.upload_asset(
                data=data,
                filename=image_filename(index, content_type),
                content_type=content_type,
                device_asset_id=f"{guid}-{index}-{hashlib.sha1(data).hexdigest()[:12]}",
                file_created_at=_now(),
            )
            asset_ids.append(uploaded["id"])
            record = {"url": image_url, "asset_id": uploaded["id"], "status": "uploaded", "warning": ""}
            if uploaded.get("duplicate"):
                warnings.append(f"圖片已存在於 Immich，重複上傳略過：{image_url}")
        except Exception as error:
            warnings.append(f"圖片上傳失敗，保留原始連結：{image_url}（{error}）")
            record = {"url": image_url, "asset_id": "", "status": "remote", "warning": str(error)}
        images.append(record)

    progress(60, "建立 GUID 標籤與分享連結…")
    share_url = ""
    album_id = ""
    mapping: dict[str, str] = {}
    if asset_ids:
        try:
            tag_id = client.ensure_tag(guid)
            client.tag_assets(tag_id, asset_ids)
            link = client.create_shared_link(asset_ids, description=title or source_url)
            share_url = link["share_url"]
            for record in images:
                if record.get("asset_id"):
                    mapping[record["url"]] = client.asset_thumbnail_url(record["asset_id"], link["key"])
            if create_album and title:
                album_id = client.create_album(title, asset_ids)
        except ImmichError as error:
            warnings.append(f"Immich 標籤或分享連結建立失敗：{error}")

    for record in images:
        embedded = mapping.get(record.get("url"))
        if embedded:
            record["embedded_url"] = embedded

    return {"images": images, "share_url": share_url, "album_id": album_id, "warnings": warnings}


# --------------------------------------------------------------------------- #
# Job store                                                                    #
# --------------------------------------------------------------------------- #

MAX_STORED_JOBS = 50
_job_lock = threading.RLock()
_jobs: dict[str, dict[str, Any]] = {}
_executor: Optional[ThreadPoolExecutor] = None


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _get_executor() -> ThreadPoolExecutor:
    global _executor
    with _job_lock:
        if _executor is None:
            _executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="web-article")
        return _executor


def shutdown_jobs() -> None:
    """Stop worker threads; called from the FastAPI shutdown event."""
    global _executor
    with _job_lock:
        if _executor is not None:
            _executor.shutdown(wait=False, cancel_futures=True)
            _executor = None


def job_payload(job_id: str) -> Optional[dict[str, Any]]:
    """A JSON-safe snapshot of one job, or None when it is unknown."""
    with _job_lock:
        job = _jobs.get(job_id)
        if not job:
            return None
        payload = dict(job)
        payload["images"] = [dict(item) for item in job.get("images", [])]
        payload["warnings"] = list(job.get("warnings", []))
        return payload


def start_job(
    url: str,
    *,
    guid: str = "",
    web_to_markdown_api_key: str = "",
    timeout_seconds: int = 60,
    download_max_mb: int = 20,
    immich_server_url: str = "",
    immich_api_key: str = "",
    create_album: bool = False,
) -> dict[str, Any]:
    """Validate the URL, register a queued job, and hand it to the executor.

    ``guid`` is the caller's note GUID (the frontend generates one per
    capture); when omitted a fresh UUID is generated so the note and its
    Immich assets still share one identifier.
    """
    url = str(url or "").strip()
    try:
        parsed = urllib.parse.urlparse(url)
    except ValueError:
        parsed = None
    if parsed is None or parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("URL 必須以 http:// 或 https:// 開頭。")
    source = known_sources.match_known_source(url)
    if source:
        raise KnownSourceError(known_sources.known_source_hint(url))
    blocked_reason = blocked_host_reason(url)
    if blocked_reason:
        raise ValueError(blocked_reason)

    note_guid = _validated_note_guid(guid)
    job_id = f"web-{uuid.uuid4().hex[:12]}"
    job: dict[str, Any] = {
        "job_id": job_id,
        "url": url,
        "status": "queued",
        "progress": 0,
        "message": "排隊中",
        "guid": note_guid,
        "title": "",
        "markdown": "",
        "images": [],
        "share_url": "",
        "album_id": "",
        "warnings": [],
        "error": "",
        "created_at": _now(),
        "updated_at": _now(),
    }
    with _job_lock:
        _jobs[job_id] = job
        while len(_jobs) > MAX_STORED_JOBS:
            _jobs.pop(next(iter(_jobs)))
    options = {
        "guid": note_guid,
        "web_to_markdown_api_key": web_to_markdown_api_key,
        "timeout_seconds": timeout_seconds,
        "download_max_mb": download_max_mb,
        "immich_server_url": immich_server_url,
        "immich_api_key": immich_api_key,
        "create_album": create_album,
    }
    _get_executor().submit(_run_job, job_id, url, options)
    return job_payload(job_id)


# --------------------------------------------------------------------------- #
# Job runner                                                                   #
# --------------------------------------------------------------------------- #

def _run_job(job_id: str, url: str, options: dict[str, Any]) -> None:
    def update(**changes: Any) -> None:
        with _job_lock:
            stored = _jobs.get(job_id)
            if stored:
                stored.update(changes)
                stored["updated_at"] = _now()

    def progress(percent: int, message: str) -> None:
        update(progress=percent, message=message)

    try:
        progress(5, "透過 md.genedai.me 抓取文章…")
        markdown = fetch_markdown(
            url,
            api_key=options["web_to_markdown_api_key"],
            timeout_seconds=options["timeout_seconds"],
        )
        guid = options["guid"]
        title = extract_title(markdown)
        update(guid=guid, title=title)
        progress(20, "Markdown 轉換完成")

        warnings: list[str] = []
        body_chars = article_body_chars(markdown)
        if body_chars < SHORT_BODY_CHARS:
            warnings.append(
                f"md.genedai.me 只抓到極少的內文（{body_chars} 字，多半只有標題）。匿名層級無法使用瀏覽器引擎，"
                "到 Settings 填入 md.genedai.me API key（mk_…）後重試，或這個網站可能不支援自動轉換。"
            )

        image_urls = extract_image_urls(markdown, base_url=url)
        media = store_note_media(
            image_urls,
            source_url=url,
            guid=guid,
            title=title,
            immich_server_url=options["immich_server_url"],
            immich_api_key=options["immich_api_key"],
            timeout_seconds=options["timeout_seconds"],
            download_max_mb=options["download_max_mb"],
            create_album=bool(options.get("create_album")),
            on_progress=progress,
        )
        warnings.extend(media["warnings"])
        update(share_url=media["share_url"], album_id=media["album_id"])
        with _job_lock:
            stored = _jobs.get(job_id)
            if stored:
                stored["images"] = [dict(item) for item in media["images"]]

        progress(85, "重寫筆記中的圖片連結…")
        mapping = {
            record["url"]: record["embedded_url"]
            for record in media["images"]
            if record.get("embedded_url")
        }
        final_markdown = rewrite_image_links(markdown, mapping)
        update(status="completed", progress=100, message="完成", markdown=final_markdown, warnings=warnings)
    except Exception as error:
        update(status="error", message="失敗", error=str(error))