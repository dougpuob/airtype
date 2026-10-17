"""Background capture for article and post clip requests.

Voice clips stay on the transcription worker. This module finishes the other
two kinds and writes the Obsidian draft back into the request JSON.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any, Callable
from urllib.parse import urlparse

from . import clip_requests
from . import web_article
from .note_id import note_guid_for_source

Chat = Callable[..., str]
SettingsFn = Callable[[], dict[str, Any]]
ThreadsFn = Callable[[str], dict[str, Any]]
PublicPostFn = Callable[[str], dict[str, Any]]

POLISH_SYSTEM = (
    "你是嚴謹、克制的繁體中文編輯。忠實保留原文的觀點、時間線與事實，"
    "不得加入新資訊、評論、推測、俏皮語氣、誇張修辭或宣傳式文字。"
)
POLISH_USER = """請將以下內容整理成一篇通順、簡潔、語氣中性的繁體中文文章。

要求：
1. 移除重複段落、重複敘述、社群介面文字與 hashtag 雜訊；同一事實只保留一次。
2. 只做必要的語句銜接與錯字修正，不要改寫成花俏、幽默或煽動性的文風。
3. 保留原本段落與事實順序；不新增標題、標籤、摘要或任何說明。
4. 只輸出完成後的文章正文。

原始內容：
{source}"""

KIND_TAGS = {"article": "web-article", "post": "capture-post", "voice": "speech-to-text"}
ORIGINAL_HEADING = {"article": "Original Content", "post": "Original Content", "voice": "Original Transcript"}


def run_article(request_id: str, url: str, *, settings: SettingsFn, chat: Chat) -> None:
    if _stopped(request_id):
        return
    clip_requests.update(request_id, status="running", progress=5, message="擷取網頁文章")
    app_settings = settings()
    web_to_markdown = app_settings.get("web_to_markdown") or {}
    immich = app_settings.get("immich") or {}
    markdown = web_article.fetch_markdown(
        url,
        api_key=str(web_to_markdown.get("api_key") or ""),
        timeout_seconds=int(web_to_markdown.get("timeout_seconds") or 60),
    )
    if _stopped(request_id):
        return
    title = web_article.extract_title(markdown)
    guid = note_guid_for_source(url)
    image_urls = web_article.extract_image_urls(markdown, base_url=url)
    media = web_article.store_note_media(
        image_urls,
        source_url=url,
        guid=guid,
        title=title,
        immich_server_url=str(immich.get("server_url") or ""),
        immich_api_key=str(immich.get("api_key") or ""),
        timeout_seconds=int(web_to_markdown.get("timeout_seconds") or 60),
        download_max_mb=int(web_to_markdown.get("download_max_mb") or 20),
        create_album=bool(immich.get("create_album")),
    )
    mapping = {
        record["url"]: record["embedded_url"]
        for record in media["images"]
        if record.get("embedded_url")
    }
    content = web_article.rewrite_image_links(markdown, mapping)
    _finish_text(
        request_id,
        kind="article",
        content=content,
        fallback_title=title,
        sources=[url],
        guid=guid,
        share_url=str(media.get("share_url") or ""),
        settings=settings,
        chat=chat,
    )


def run_post(
    request_id: str,
    url: str,
    *,
    settings: SettingsFn,
    chat: Chat,
    collect_threads: ThreadsFn,
    fetch_public_post: PublicPostFn,
) -> None:
    if _stopped(request_id):
        return
    clip_requests.update(request_id, status="running", progress=8, message="擷取貼文")
    host = urlparse(url).hostname or ""
    if host.endswith("threads.com") or host.endswith("threads.net"):
        payload = collect_threads(url)
        posts = payload.get("posts") if isinstance(payload.get("posts"), list) else []
        content = str(payload.get("markdown") or "").strip()
        guid = str(payload.get("guid") or "") or note_guid_for_source(url)
        sources = [str(post.get("url") or "") for post in posts if isinstance(post, dict)]
        sources = [url, *[item for item in sources if item]]
        media_urls = []
        for post in posts:
            if isinstance(post, dict):
                media_urls.extend(post.get("media_urls") or [])
        fallback_title = str(payload.get("author") or "") or _first_line(content)
    else:
        payload = fetch_public_post(url)
        content = str(payload.get("markdown") or payload.get("text") or "").strip()
        guid = str(payload.get("guid") or "") or note_guid_for_source(url)
        sources = [url]
        media_urls = list(payload.get("media_urls") or [])
        fallback_title = str(payload.get("title") or "") or _first_line(content)
    if not content:
        raise RuntimeError("沒有取得貼文內容")
    if _stopped(request_id):
        return
    app_settings = settings()
    web_to_markdown = app_settings.get("web_to_markdown") or {}
    immich = app_settings.get("immich") or {}
    image_urls = [item for item in media_urls if isinstance(item, str) and not _looks_like_video(item)]
    share_url = ""
    if image_urls:
        clip_requests.update(request_id, progress=25, message="上傳照片")
        media = web_article.store_note_media(
            image_urls,
            source_url=url,
            guid=guid,
            title=fallback_title,
            immich_server_url=str(immich.get("server_url") or ""),
            immich_api_key=str(immich.get("api_key") or ""),
            timeout_seconds=int(web_to_markdown.get("timeout_seconds") or 60),
            download_max_mb=int(web_to_markdown.get("download_max_mb") or 20),
            create_album=bool(immich.get("create_album")),
        )
        share_url = str(media.get("share_url") or "")
        mapping = {
            record["url"]: record["embedded_url"]
            for record in media["images"]
            if record.get("embedded_url")
        }
        content = web_article.rewrite_image_links(content, mapping)
    _finish_text(
        request_id,
        kind="post",
        content=content,
        fallback_title=fallback_title,
        sources=_unique(sources),
        guid=guid,
        share_url=share_url,
        settings=settings,
        chat=chat,
    )


def finish_voice(
    request_id: str,
    *,
    content: str,
    polished: str,
    title: str,
    ai_tags: str,
    sources: list[str],
    guid: str,
    share_url: str = "",
) -> None:
    """Write a completed voice draft. The transcription worker already ran the LLM."""
    if _stopped(request_id):
        return
    fields = build_draft(
        kind="voice",
        title=title,
        content=content,
        polished=polished,
        ai_tags=ai_tags,
        sources=sources,
        guid=guid,
        share_url=share_url,
    )
    clip_requests.update(
        request_id,
        status="completed",
        progress=100,
        message="已完成",
        error="",
        published=True,
        **fields,
    )


def build_draft(
    *,
    kind: str,
    title: str,
    content: str,
    polished: str,
    ai_tags: str,
    sources: list[str],
    guid: str,
    share_url: str,
) -> dict[str, Any]:
    date_parts = _date_parts()
    clean_title = _sanitize_title(title) or "Untitled"
    note_title = f"{date_parts['date']} {clean_title}"
    source_list = _unique(sources)
    tags = _unique([
        date_parts["date"],
        "airtype",
        KIND_TAGS.get(kind, "airtype"),
        *_domain_tags(source_list),
        *[part.strip() for part in ai_tags.replace("，", ",").split(",") if part.strip()],
    ])
    note = _note(
        kind=kind,
        title=clean_title,
        content=content,
        polished=polished,
        ai_tags=ai_tags,
        sources=source_list,
        tags=tags,
        guid=guid,
        share_url=share_url,
        date_parts=date_parts,
    )
    return {
        "title": clean_title,
        "content": content,
        "polished_content": polished,
        "ai_tags": ai_tags,
        "sources": source_list,
        "tags": tags,
        "datetime": date_parts["datetime"],
        "guid": guid,
        "share_url": share_url,
        "note_title": note_title,
        "note": note,
    }


def _finish_text(
    request_id: str,
    *,
    kind: str,
    content: str,
    fallback_title: str,
    sources: list[str],
    guid: str,
    share_url: str,
    settings: SettingsFn,
    chat: Chat,
) -> None:
    if _stopped(request_id):
        return
    clip_requests.update(request_id, status="running", progress=80, message="AI 潤稿")
    polished = ""
    try:
        polished = chat(POLISH_SYSTEM, POLISH_USER.format(source=content), "polish").strip()
    except Exception:
        polished = ""
    if _stopped(request_id):
        return
    app_settings = settings()
    capture_post = app_settings.get("capture_post") or {}
    title = _sanitize_title(fallback_title)
    if capture_post.get("ai_title_enabled", True):
        clip_requests.update(request_id, progress=90, message="AI 標題")
        system_prompt = str(capture_post.get("title_system_prompt") or "").strip()
        try:
            generated = chat(system_prompt or "只輸出一個標題。", polished or content, "title").strip()
            title = _sanitize_title(generated.splitlines()[0] if generated else "") or title
        except Exception:
            title = title or _sanitize_title(content[:30])
    if _stopped(request_id):
        return
    clip_requests.update(request_id, progress=96, message="AI 標籤")
    tags = ""
    try:
        from .ai_tags import build_ai_tags_prompt, normalize_ai_tags
        from .ai_tags import AI_TAGS_SYSTEM_PROMPT

        raw_tags = chat(AI_TAGS_SYSTEM_PROMPT, build_ai_tags_prompt(polished or content, title), "tags")
        tags = normalize_ai_tags(raw_tags)
    except Exception:
        tags = ""
    if _stopped(request_id):
        return
    fields = build_draft(
        kind=kind,
        title=title or "Untitled",
        content=content,
        polished=polished,
        ai_tags=tags,
        sources=sources,
        guid=guid,
        share_url=share_url,
    )
    clip_requests.update(
        request_id,
        status="completed",
        progress=100,
        message="已完成",
        error="",
        published=True,
        **fields,
    )


def _stopped(request_id: str) -> bool:
    if not clip_requests.is_cancelled(request_id):
        return False
    current = clip_requests.get(request_id)
    if current and current.get("status") not in {"completed", "failed"}:
        clip_requests.update(
            request_id,
            status="failed",
            progress=100,
            message="失敗",
            error="已停止",
            published=True,
        )
    return True


def _note(
    *,
    kind: str,
    title: str,
    content: str,
    polished: str,
    ai_tags: str,
    sources: list[str],
    tags: list[str],
    guid: str,
    share_url: str,
    date_parts: dict[str, str],
) -> str:
    source_yaml = "\n".join(f'  - "{_yaml_quote(item)}"' for item in sources)
    tag_yaml = "\n".join(f"  - {item}" for item in tags)
    share_line = f"immich_share: {share_url}\n" if share_url else ""
    heading = ORIGINAL_HEADING.get(kind, "Original Content")
    return (
        f"---\n"
        f"title: {date_parts['date']} {title}\n"
        f"guid: {guid}\n"
        f"sources:\n{source_yaml}\n"
        f"{share_line}"
        f"datetime: {date_parts['datetime']}\n"
        f"tags:\n{tag_yaml}\n"
        f"---\n\n---\n\n# Title\n\n{title}\n\n---\n\n# Notes\n\n\n\n---\n\n"
        f"# AI Tags\n\n{ai_tags}\n\n---\n\n# AI Polished Article\n\n{polished}\n\n---\n\n"
        f"# {heading}\n\n{content}\n\n---\n\nEND"
    )


def _date_parts() -> dict[str, str]:
    current = datetime.now().astimezone()
    day = current.strftime("%Y-%m-%d")
    return {"date": day, "datetime": current.strftime("%Y-%m-%d %H:%M")}


def _sanitize_title(text: str) -> str:
    cleaned = "".join(" " if char in '\\/:*?"<>|;；：' or ord(char) < 32 else char for char in str(text or ""))
    return " ".join(cleaned.split()).strip()


def _yaml_quote(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def _domain_tags(urls: list[str]) -> list[str]:
    tags = []
    for value in urls:
        host = (urlparse(value).hostname or "").lower().removeprefix("www.")
        if not host or host.endswith(".ts.net"):
            continue
        name = host.split(".")[0]
        if name and name not in tags:
            tags.append(name)
    return tags


def _unique(values: list[str]) -> list[str]:
    seen = set()
    result = []
    for value in values:
        item = str(value or "").strip()
        if not item or item in seen:
            continue
        seen.add(item)
        result.append(item)
    return result


def _first_line(text: str) -> str:
    line = next((part.strip() for part in text.splitlines() if part.strip()), "")
    return _sanitize_title(line[:40])


def _looks_like_video(url: str) -> bool:
    path = urlparse(url).path.lower()
    return path.endswith((".mp4", ".mov", ".webm", ".m4v", ".mkv"))
