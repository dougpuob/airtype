"""Public Threads chain collection for the Post Weaver API.

Threads server-renders a JSON payload in ``script[data-sjs]`` on public post
pages. This module reads that structured data, then fetches related post pages
when the first response does not contain the author's full continuation spine.
"""

from __future__ import annotations

from dataclasses import dataclass
from html.parser import HTMLParser
import html
import json
import os
import re
import urllib.parse
import urllib.request
from typing import Any, Iterable

from .note_id import canonical_source_id, note_guid_for_source


_THREADS_HOSTS = {"threads.com", "www.threads.com", "threads.net", "www.threads.net"}
_POST_PATH = re.compile(r"^/@(?P<author>[^/?#]+)/post/(?P<code>[A-Za-z0-9_-]+)", re.IGNORECASE)
_SHARE_PATH = re.compile(r"^/share/(?P<share_id>[A-Za-z0-9_-]+)/?", re.IGNORECASE)


@dataclass(frozen=True)
class ThreadsPost:
    """The small, stable subset Post Weaver needs from a Threads post."""

    id: str
    url: str
    author: str
    text: str
    media_urls: tuple[str, ...] = ()

    def as_dict(self) -> dict[str, Any]:
        return {"url": self.url, "text": self.text, "media_urls": list(self.media_urls)}


def posts_to_markdown(posts: Iterable[Any]) -> str:
    """Compile collected posts into one Markdown document.

    Each post is its text followed by image embeds. This is the same
    original-content shape the web-article pipeline produces, so Immich
    rewriting and the Obsidian clip template can treat posts and articles
    the same way.
    """
    blocks: list[str] = []
    seen: set[str] = set()
    for post in posts or []:
        if isinstance(post, ThreadsPost):
            text = post.text
            media = post.media_urls
        elif isinstance(post, dict):
            text = str(post.get("text") or "")
            media = post.get("media_urls") or ()
        else:
            continue
        parts: list[str] = []
        stripped = str(text or "").strip()
        if stripped:
            parts.append(stripped)
        for url in media:
            clean = str(url or "").strip()
            if clean:
                parts.append(f"![]({clean})")
        block = "\n\n".join(parts).strip()
        if not block:
            continue
        key = re.sub(r"[\s\u200b-\u200d\ufeff]+", " ", block).strip()
        if key in seen:
            continue
        seen.add(key)
        blocks.append(block)
    return "\n\n".join(blocks)


WARNING_NOT_OP_CHAIN = "不是樓主連發，沒有收連續篇"
WARNING_UNCONFIRMED_OP = "無法確認樓主，這串可能不完整"
WARNING_INCOMPLETE = "這串可能不完整"


@dataclass(frozen=True)
class _ThreadEntry:
    """One post plus the reply metadata needed to walk a continuation spine."""

    post: ThreadsPost
    is_reply: bool
    reply_to_author: str
    parent_code: str
    taken_at: int
    reply_count: int
    has_reply_info: bool


class ThreadsChainCollector:
    """Collect one author's continuation spine from a Threads post URL.

    The URL is an anchor for the conversation. Same-author self-replies and
    unmarked consecutive posts in that conversation are kept; replies to other
    people are not. Additional post pages are fetched when expanding so a
    truncated first HTML response can still yield the rest of the spine.
    Cookies are used when provided; missing later pages become a warning
    rather than a failed import.
    """

    def __init__(
        self,
        *,
        max_posts: int = 100,
        timeout_seconds: int = 20,
        cookies_path: str = "",
        cookie_header: str = "",
        storage_state_path: str = "",
    ) -> None:
        self.max_posts = max(1, min(int(max_posts), 500))
        self.timeout_seconds = timeout_seconds
        self.cookies_path = cookies_path
        self.cookie_header = cookie_header
        self.storage_state_path = storage_state_path
        self._fetch_use_cookies = True

    def collect(self, url: str) -> dict[str, Any]:
        # Logged-in HTML often hides the self-reply spine that the public page
        # already contains, so the first pass is always anonymous.
        self._fetch_use_cookies = False
        canonical_url, author, target_code = self._normalize_or_resolve_url(url)
        try:
            anonymous = self._collect_from_pages(canonical_url, author, target_code, {}, expand=True)
        except RuntimeError:
            anonymous = {"author": author, "posts": [], "warnings": [], "_reply_count": 0}
        anonymous["fetch"] = "anonymous"
        best = anonymous

        if self._has_auth() and self._needs_richer_fetch(best):
            self._fetch_use_cookies = True
            try:
                authed = self._collect_from_pages(canonical_url, author, target_code, {}, expand=True)
            except RuntimeError:
                authed = {"author": author, "posts": [], "warnings": [], "_reply_count": 0}
            authed["fetch"] = "cookies"
            if len(authed.get("posts") or []) > len(best.get("posts") or []):
                best = authed

            if self._needs_richer_fetch(best):
                try:
                    browser_page = self._fetch_with_browser(canonical_url)
                except Exception:
                    browser_page = ""
                if browser_page:
                    browser = self._collect_from_pages(
                        canonical_url, author, target_code, {canonical_url: browser_page}, expand=True
                    )
                    browser["fetch"] = "browser"
                    if len(browser.get("posts") or []) > len(best.get("posts") or []):
                        best = browser

        if self._needs_richer_fetch(best):
            warnings = list(best.get("warnings") or [])
            if WARNING_INCOMPLETE not in warnings and WARNING_UNCONFIRMED_OP not in warnings:
                warnings.append(WARNING_INCOMPLETE)
            best["warnings"] = warnings
        if not best.get("posts"):
            raise RuntimeError(
                "Threads did not expose public post data for this URL. The post may be private, "
                "login-walled, deleted, or temporarily rate-limited."
            )
        return self._public_result(best)

    def collect_page(self, url: str, page: str) -> dict[str, Any]:
        """Collect a chain from an already fetched public Threads page.

        Keeping parsing separate from fetching makes the same production
        collector usable with recorded page fixtures in regression tests.
        Expansion (parent/continuation page fetches) is intentionally off here.
        """
        canonical_url, author, target_code = self._normalize_url(url)
        return self._public_result(
            self._collect_from_pages(canonical_url, author, target_code, {canonical_url: page}, expand=False)
        )

    def _normalize_url(self, url: str) -> tuple[str, str, str]:
        parsed = urllib.parse.urlparse(str(url or "").strip())
        if parsed.scheme not in {"http", "https"} or parsed.hostname not in _THREADS_HOSTS:
            raise ValueError("URL must be a public threads.com or threads.net post URL")
        match = _POST_PATH.match(parsed.path)
        if not match:
            raise ValueError("URL must point to a Threads post, such as https://www.threads.com/@author/post/POST_ID")
        path = f"/@{match.group('author')}/post/{match.group('code')}"
        return (
            urllib.parse.urlunparse(("https", "www.threads.com", path, "", "", "")),
            urllib.parse.unquote(match.group("author")),
            match.group("code"),
        )

    def _normalize_or_resolve_url(self, url: str) -> tuple[str, str, str]:
        parsed = urllib.parse.urlparse(str(url or "").strip())
        if parsed.scheme not in {"http", "https"} or parsed.hostname not in _THREADS_HOSTS:
            raise ValueError("URL must be a public threads.com or threads.net post URL")
        if _SHARE_PATH.match(parsed.path):
            return self._normalize_url(self._resolve_share_url(url))
        return self._normalize_url(url)

    def _resolve_share_url(self, url: str) -> str:
        headers = self._headers(url)
        try:
            from curl_cffi import requests as curl_requests

            response = curl_requests.get(
                url,
                headers=headers,
                impersonate="chrome131",
                timeout=self.timeout_seconds,
                allow_redirects=True,
            )
            response.raise_for_status()
            resolved = str(response.url)
        except ImportError:
            request = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                resolved = response.geturl()
        except Exception as error:
            raise RuntimeError(f"Could not resolve the Threads share URL: {error}") from error

        if resolved.rstrip("/") == url.rstrip("/"):
            raise RuntimeError("Threads share URL did not redirect to a post URL.")
        return resolved

    def _fetch(self, url: str) -> str:
        """Fetch with Chrome TLS impersonation when curl-cffi is available."""
        headers = self._headers(url, use_cookies=getattr(self, "_fetch_use_cookies", True))
        try:
            from curl_cffi import requests as curl_requests

            response = curl_requests.get(url, headers=headers, impersonate="chrome131", timeout=self.timeout_seconds)
            response.raise_for_status()
            return response.text
        except ImportError:
            request = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                return response.read(3_000_000).decode("utf-8", errors="replace")
        except Exception as error:
            raise RuntimeError(f"Could not open the public Threads post: {error}") from error

    def _headers(self, url: str, *, use_cookies: bool | None = None) -> dict[str, str]:
        headers = {
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131 Safari/537.36"
            ),
        }
        if use_cookies is None:
            use_cookies = getattr(self, "_fetch_use_cookies", True)
        if use_cookies:
            cookie_header = self.cookie_header or _cookies_header_for_url(self.cookies_path, url)
            if cookie_header:
                headers["Cookie"] = cookie_header
        return headers

    def _has_auth(self) -> bool:
        if str(self.cookie_header or "").strip():
            return True
        cookies_path = os.path.expanduser(str(self.cookies_path or "").strip())
        if cookies_path and os.path.exists(cookies_path):
            return True
        state = os.path.expanduser(str(self.storage_state_path or "").strip())
        return bool(state and os.path.exists(state))

    def _needs_richer_fetch(self, result: dict[str, Any]) -> bool:
        posts = result.get("posts") or []
        if not posts:
            return True
        return len(posts) == 1 and int(result.get("_reply_count") or 0) >= 1

    def _public_result(self, result: dict[str, Any]) -> dict[str, Any]:
        result.pop("_reply_count", None)
        result["kind"] = "post"
        result["markdown"] = posts_to_markdown(result.get("posts") or [])
        source_url = str(result.get("url") or "")
        if not source_url:
            posts = result.get("posts") or []
            source_url = str((posts[0] or {}).get("url") or "") if posts else ""
        if source_url:
            result["guid"] = note_guid_for_source(source_url)
            result["source_id"] = canonical_source_id(source_url)
        return result

    def _fetch_with_browser(self, url: str) -> str:
        path = os.path.expanduser(str(self.storage_state_path or "").strip())
        if not path or not os.path.exists(path):
            raise RuntimeError("No Threads browser session is available")
        from playwright.sync_api import sync_playwright

        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            try:
                context = browser.new_context(storage_state=path)
                page = context.new_page()
                page.goto(url, wait_until="domcontentloaded", timeout=max(self.timeout_seconds, 15) * 1000)
                page.wait_for_timeout(2500)
                return page.content()
            finally:
                browser.close()

    def _collect_from_pages(
        self,
        canonical_url: str,
        author: str,
        target_code: str,
        pages: dict[str, str],
        *,
        expand: bool,
    ) -> dict[str, Any]:
        conversation: list[_ThreadEntry] = []
        fetched: set[str] = set()
        pending = [canonical_url]
        expansion_failed = False
        reached_max = False

        while pending:
            page_url = self._canonical_post_url(pending.pop(0))
            if not page_url or page_url in fetched:
                continue
            if page_url in pages:
                html = pages[page_url]
            elif expand:
                try:
                    html = self._fetch(page_url)
                except Exception:
                    expansion_failed = True
                    fetched.add(page_url)
                    continue
                pages[page_url] = html
            else:
                break

            fetched.add(page_url)
            known_codes = {_entry_code(entry) for entry in conversation}
            known_codes.add(target_code)
            group = _conversation_group(_DataSjsParser.payloads(html), known_codes)
            if group:
                conversation = _merge_entries(conversation, group)

            continuations = [entry for entry in conversation if _is_continuation(entry, author)]
            if len(continuations) >= self.max_posts:
                reached_max = True
                break
            if not expand:
                break

            for next_url in self._expansion_urls(conversation, author, target_code, fetched):
                if next_url not in fetched and next_url not in pending:
                    pending.append(next_url)

        posts, warnings = _finish_chain(
            author,
            target_code,
            conversation,
            expansion_failed=expansion_failed,
            reached_max=reached_max,
            max_posts=self.max_posts,
        )
        page = pages.get(canonical_url, "")
        if not posts:
            preview = _meta_content(page, "og:description") or _meta_content(page, "description")
            if preview:
                posts = [ThreadsPost("", canonical_url, author, preview)]

        if not posts:
            raise RuntimeError(
                "Threads did not expose public post data for this URL. The post may be private, "
                "login-walled, deleted, or temporarily rate-limited."
            )
        target_entry = _find_entry(conversation, target_code)
        return {
            "author": author,
            "url": canonical_url,
            "posts": [post.as_dict() for post in posts],
            "warnings": warnings,
            "_reply_count": target_entry.reply_count if target_entry else 0,
        }

    def _canonical_post_url(self, url: str) -> str:
        try:
            canonical, _, _ = self._normalize_url(url)
        except ValueError:
            return str(url or "").strip().rstrip("/")
        return canonical

    def _expansion_urls(
        self,
        conversation: list[_ThreadEntry],
        author: str,
        target_code: str,
        fetched: set[str],
    ) -> list[str]:
        target = _find_entry(conversation, target_code)
        if target and _is_reply_to_other(target, author):
            return []
        first = conversation[0] if conversation else None
        if first and (
            first.post.author.casefold() != author.casefold() or _is_reply_to_other(first, author)
        ):
            return []

        urls: list[str] = []
        if _same_author_op(conversation, author) is None:
            seed = first or target
            if seed:
                parent = _parent_url(seed)
                if parent:
                    urls.append(parent)
                if seed.post.url:
                    urls.append(seed.post.url)

        op_entry = _same_author_op(conversation, author)
        if op_entry and op_entry.post.url:
            urls.append(op_entry.post.url)

        continuations = [entry for entry in conversation if _is_continuation(entry, author)]
        if continuations and continuations[-1].post.url:
            urls.append(continuations[-1].post.url)

        seen: set[str] = set()
        unique: list[str] = []
        for raw_url in urls:
            canonical = self._canonical_post_url(raw_url)
            if not canonical or canonical in fetched or canonical in seen:
                continue
            seen.add(canonical)
            unique.append(canonical)
        return unique


class _DataSjsParser(HTMLParser):
    """Extract JSON only from the structured public payload scripts."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=False)
        self.payloads: list[Any] = []
        self._inside_data_sjs = False
        self._chunks: list[str] = []

    @classmethod
    def payloads(cls, page: str) -> list[Any]:
        parser = cls()
        parser.feed(page)
        parser.close()
        return parser.payloads

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "script":
            return
        values = {name.lower(): value for name, value in attrs}
        if values.get("type", "").lower() == "application/json" and "data-sjs" in values:
            self._inside_data_sjs = True
            self._chunks = []

    def handle_data(self, data: str) -> None:
        if self._inside_data_sjs:
            self._chunks.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() != "script" or not self._inside_data_sjs:
            return
        self._inside_data_sjs = False
        try:
            self.payloads.append(json.loads("".join(self._chunks)))
        except json.JSONDecodeError:
            # Some unrelated data-sjs blocks are not standalone JSON. Ignore
            # them and retain the parseable post payloads.
            pass
        self._chunks = []


def _walk_thread_items(value: Any) -> Iterable[ThreadsPost]:
    """Depth-first walk of Threads' nested ``thread_items`` response objects."""
    if isinstance(value, dict):
        items = value.get("thread_items")
        if isinstance(items, list):
            for item in items:
                if isinstance(item, dict):
                    post = _threads_post(item.get("post"))
                    if post:
                        yield post
                    # A reply tree may be a sibling of the post inside this
                    # item, so recurse after yielding to preserve page order.
                    for key, child in item.items():
                        if key != "post":
                            yield from _walk_thread_items(child)
        for key, child in value.items():
            if key != "thread_items":
                yield from _walk_thread_items(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk_thread_items(child)


def _thread_item_groups(value: Any) -> Iterable[list[Any]]:
    """Yield each distinct, direct post group in page order.

    Besides the classic ``thread_items`` lists, the current Threads payload
    also exposes the anchor post as ``data.media`` and the author's
    continuation spine as ``text_post_app_info.self_thread.posts.edges``.
    Both are yielded as post groups so the spine joining logic treats them
    like any other conversation fragment.
    """
    yield from _item_groups(value, frozenset())


def _item_groups(value: Any, seen: frozenset) -> Iterable[list[Any]]:
    if isinstance(value, dict):
        marker = id(value)
        if marker in seen:
            return
        seen = seen | {marker}
        items = value.get("thread_items")
        if isinstance(items, list):
            yield items
        media = value.get("media")
        if _looks_like_post(media):
            yield [media]
        edges = _self_thread_edges(value)
        if edges:
            yield edges
        for key, child in value.items():
            if key == "thread_items":
                continue
            yield from _item_groups(child, seen)
    elif isinstance(value, list):
        for child in value:
            yield from _item_groups(child, seen)


def _self_thread_edges(value: dict) -> list[dict]:
    thread = value.get("self_thread")
    if not isinstance(thread, dict):
        return []
    posts = thread.get("posts")
    if not isinstance(posts, dict):
        return []
    edges = posts.get("edges")
    if not isinstance(edges, list):
        return []
    nodes = [edge.get("node") for edge in edges if isinstance(edge, dict)]
    return [node for node in nodes if isinstance(node, dict)]


def _looks_like_post(value: Any) -> bool:
    """A raw post object carries its own code, caption, and user fields."""
    if not isinstance(value, dict):
        return False
    has_id = bool(value.get("code") or value.get("pk") or value.get("id"))
    has_caption = isinstance(value.get("caption"), (str, dict))
    has_user = isinstance(value.get("user"), dict)
    return has_id and has_caption and has_user


def _conversation_group(payloads: Iterable[Any], known_codes: set[str]) -> list[_ThreadEntry]:
    """Return the conversation spine that contains a known post.

    Top-level ``thread_items`` groups are independent conversations, profile
    previews, or recommendations. Threads often splits one author's
    continuation across adjacent groups in the same payload, and logged-in
    pages may put the OP in one ``data-sjs`` script and the self-reply spine
    in a later script. Nested ``thread_items`` under a conversation item are
    replies in the same tree.
    """
    codes = {code for code in known_codes if code}
    if not codes:
        return []

    payload_groups = [
        [_flatten_conversation_items(items) for items in _thread_item_groups(payload)]
        for payload in payloads
    ]

    collected: list[_ThreadEntry] = []
    for groups in payload_groups:
        if any(_entry_code(entry) in codes for group in groups for entry in group):
            collected = _merge_entries(collected, _join_payload_groups(groups, codes))
            codes |= {_entry_code(entry) for entry in collected}

    if not collected:
        return []

    target = next((entry for entry in collected if _entry_code(entry) in known_codes), collected[0])
    author = target.post.author
    while True:
        before = {_entry_code(entry) for entry in collected}
        for groups in payload_groups:
            for group in groups:
                if _group_continues_spine(group, author, collected, toward_root=True) or _group_continues_spine(
                    group, author, collected, toward_root=False
                ):
                    collected = _merge_entries(collected, group)
        after = {_entry_code(entry) for entry in collected}
        if after <= before:
            break
    return collected


def _join_payload_groups(groups: list[list[_ThreadEntry]], known_codes: set[str]) -> list[_ThreadEntry]:
    target_index = next(
        index
        for index, group in enumerate(groups)
        if any(_entry_code(entry) in known_codes for entry in group)
    )
    collected = list(groups[target_index])
    seed = next((entry for entry in collected if _entry_code(entry) in known_codes), collected[0])
    author = seed.post.author

    for index in range(target_index - 1, -1, -1):
        if not _group_continues_spine(groups[index], author, collected, toward_root=True):
            break
        collected = groups[index] + collected

    for index in range(target_index + 1, len(groups)):
        if not _group_continues_spine(groups[index], author, collected, toward_root=False):
            break
        collected = collected + groups[index]
    return collected


def _group_continues_spine(
    group: list[_ThreadEntry],
    author: str,
    collected: list[_ThreadEntry],
    *,
    toward_root: bool,
) -> bool:
    same_author = [entry for entry in group if entry.post.author.casefold() == author.casefold()]
    if not same_author or any(_is_reply_to_other(entry, author) for entry in same_author):
        return False
    collected_codes = {_entry_code(entry) for entry in collected}
    for entry in same_author:
        if entry.parent_code and entry.parent_code in collected_codes:
            return True
        if entry.is_reply and entry.reply_to_author.casefold() == author.casefold():
            return True
        if not entry.has_reply_info:
            return True
        if toward_root and not entry.is_reply and _same_author_op(collected, author) is None:
            return True
    return False


def _flatten_conversation_items(items: Any) -> list[_ThreadEntry]:
    entries: list[_ThreadEntry] = []
    if not isinstance(items, list):
        return entries
    for item in items:
        if not isinstance(item, dict):
            continue
        raw_post = item.get("post")
        # The current Threads payload nests raw post objects directly (for
        # example ``data.media`` and ``self_thread.posts.edges[].node``)
        # instead of wrapping every post in a ``post`` key.
        if not isinstance(raw_post, dict) and _looks_like_post(item):
            raw_post = item
        if isinstance(raw_post, dict):
            entry = _entry_from_raw(raw_post)
            if entry is not None:
                entries.append(entry)
        for key, child in item.items():
            if key == "post":
                continue
            for nested in _thread_item_groups(child):
                entries.extend(_flatten_conversation_items(nested))
    return entries


def _entry_from_raw(raw_post: dict[str, Any]) -> _ThreadEntry | None:
    post = _threads_post(raw_post)
    if not post:
        return None
    info = raw_post.get("text_post_app_info")
    has_reply_info = isinstance(info, dict)
    is_reply = bool(has_reply_info and info.get("is_reply"))
    reply_to_author = ""
    parent_code = ""
    reply_count = 0
    if has_reply_info:
        reply_to = info.get("reply_to_author")
        if isinstance(reply_to, dict):
            reply_to_author = str(reply_to.get("username") or reply_to.get("username_text") or "").strip()
        elif isinstance(reply_to, str):
            reply_to_author = reply_to.strip()
        parent_code = _parent_code(info, raw_post)
        try:
            reply_count = int(info.get("direct_reply_count") or 0)
        except (TypeError, ValueError):
            reply_count = 0
    try:
        taken_at = int(raw_post.get("taken_at") or 0)
    except (TypeError, ValueError):
        taken_at = 0
    return _ThreadEntry(post, is_reply, reply_to_author, parent_code, taken_at, reply_count, has_reply_info)


def _parent_code(info: dict[str, Any], raw_post: dict[str, Any]) -> str:
    own = str(raw_post.get("code") or "").strip()
    for key in ("reply_to_media", "replied_to", "parent_post", "reply_to_post"):
        for source in (info, raw_post):
            value = source.get(key)
            if isinstance(value, dict):
                code = str(value.get("code") or "").strip()
                if code and code != own:
                    return code
            elif isinstance(value, str):
                code = value.strip()
                if code and code != own and re.fullmatch(r"[A-Za-z0-9_-]+", code):
                    return code
    return ""


def _entry_code(entry: _ThreadEntry) -> str:
    match = _POST_PATH.match(urllib.parse.urlparse(entry.post.url).path)
    return match.group("code") if match else ""


def _find_entry(entries: list[_ThreadEntry], target_code: str) -> _ThreadEntry | None:
    return next((entry for entry in entries if _entry_code(entry) == target_code), None)


def _merge_entries(existing: list[_ThreadEntry], incoming: list[_ThreadEntry]) -> list[_ThreadEntry]:
    merged: dict[str, _ThreadEntry] = {}

    def key_for(entry: _ThreadEntry) -> str:
        return entry.post.id or entry.post.url or _entry_code(entry)

    for entry in existing + incoming:
        key = key_for(entry)
        if not key:
            continue
        previous = merged.get(key)
        if previous is None or (not previous.has_reply_info and entry.has_reply_info):
            merged[key] = entry

    existing_codes = [_entry_code(entry) for entry in existing if _entry_code(entry)]
    incoming_codes = [_entry_code(entry) for entry in incoming if _entry_code(entry)]
    existing_set, incoming_set = set(existing_codes), set(incoming_codes)

    if incoming and existing_set <= incoming_set:
        ordered = incoming
    elif existing and incoming_set <= existing_set:
        ordered = existing
    else:
        ordered = existing + [entry for entry in incoming if key_for(entry) not in {key_for(item) for item in existing}]

    entries = []
    seen: set[str] = set()
    for entry in ordered:
        key = key_for(entry)
        chosen = merged.get(key)
        if not chosen or key in seen:
            continue
        seen.add(key)
        entries.append(chosen)
    for key, entry in merged.items():
        if key not in seen:
            entries.append(entry)

    if sum(1 for entry in entries if entry.taken_at) >= 2:
        return sorted(entries, key=lambda entry: (entry.taken_at, entry.post.id))

    roots = [entry for entry in entries if not entry.is_reply]
    replies = [entry for entry in entries if entry.is_reply]
    return roots + replies


def _is_reply_to_other(entry: _ThreadEntry, author: str) -> bool:
    return bool(
        entry.is_reply
        and entry.reply_to_author
        and entry.reply_to_author.casefold() != author.casefold()
    )


def _is_continuation(entry: _ThreadEntry, author: str) -> bool:
    if entry.post.author.casefold() != author.casefold():
        return False
    return not _is_reply_to_other(entry, author)


def _same_author_op(entries: list[_ThreadEntry], author: str) -> _ThreadEntry | None:
    return next(
        (
            entry
            for entry in entries
            if entry.post.author.casefold() == author.casefold() and not entry.is_reply
        ),
        None,
    )


def _parent_url(entry: _ThreadEntry) -> str:
    if not entry.parent_code:
        return ""
    parent_author = entry.reply_to_author or entry.post.author
    return f"https://www.threads.com/@{parent_author}/post/{entry.parent_code}"


def _finish_chain(
    author: str,
    target_code: str,
    conversation: list[_ThreadEntry],
    *,
    expansion_failed: bool,
    reached_max: bool,
    max_posts: int,
) -> tuple[list[ThreadsPost], list[str]]:
    target = _find_entry(conversation, target_code)
    if target is None:
        return [], []

    if _is_reply_to_other(target, author):
        return [target.post], [WARNING_NOT_OP_CHAIN]

    first = conversation[0] if conversation else None
    if first and (
        first.post.author.casefold() != author.casefold() or _is_reply_to_other(first, author)
    ):
        return [target.post], [WARNING_NOT_OP_CHAIN]

    continuations = [entry.post for entry in conversation if _is_continuation(entry, author)]
    posts = continuations[:max_posts] or [target.post]
    warnings: list[str] = []
    if _same_author_op(conversation, author) is None:
        warnings.append(WARNING_UNCONFIRMED_OP)
    elif expansion_failed or reached_max:
        warnings.append(WARNING_INCOMPLETE)
    return posts, warnings


def _threads_post(value: Any) -> ThreadsPost | None:
    if not isinstance(value, dict):
        return None
    user = value.get("user") if isinstance(value.get("user"), dict) else {}
    author = str(user.get("username") or user.get("username_text") or "").strip()
    post_id = str(value.get("pk") or value.get("id") or value.get("code") or "").strip()
    code = str(value.get("code") or "").strip()
    text = _caption_text(value.get("caption"))
    if not author or not post_id or not text:
        return None
    url = f"https://www.threads.com/@{author}/post/{code}" if code else ""
    return ThreadsPost(post_id, url, author, text, tuple(_media_urls(value)))


def _media_urls(post: dict[str, Any]) -> list[str]:
    """Return the image/video URLs attached to one Threads post, in order.

    Threads uses the same media objects for a single attachment and carousel
    items.  The field names below deliberately stay narrow so image URLs from
    profiles, recommendations, or reply authors are never mistaken for post
    attachments.
    """
    urls: list[str] = []
    seen: set[str] = set()

    def add(candidate: Any) -> None:
        url = str(candidate or "").strip()
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc or url in seen:
            return
        seen.add(url)
        urls.append(url)

    def collect(media: Any) -> None:
        if not isinstance(media, dict):
            return
        image_versions = media.get("image_versions2")
        if isinstance(image_versions, dict):
            candidates = image_versions.get("candidates")
            if isinstance(candidates, list):
                # The first candidate is the highest-quality rendition.
                for candidate in candidates:
                    if isinstance(candidate, dict):
                        add(candidate.get("url"))
                        break
        video_versions = media.get("video_versions")
        if isinstance(video_versions, list):
            for version in video_versions:
                if isinstance(version, dict):
                    add(version.get("url"))
                    break
        for key in ("image_url", "video_url", "thumbnail_url"):
            add(media.get(key))
        carousel = media.get("carousel_media")
        if isinstance(carousel, list):
            for item in carousel:
                collect(item)

    collect(post)
    return urls


def _caption_text(value: Any) -> str:
    if isinstance(value, str):
        text = value
    elif isinstance(value, dict):
        text = str(value.get("text") or "")
    else:
        return ""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"[^\S\n]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def _meta_content(page: str, name: str) -> str:
    escaped = re.escape(name)
    match = re.search(
        rf'<meta[^>]+(?:property|name)=["\']{escaped}["\'][^>]+content=["\']([^"\']+)', page, re.IGNORECASE
    ) or re.search(
        rf'<meta[^>]+content=["\']([^"\']+)["\'][^>]+(?:property|name)=["\']{escaped}["\']', page, re.IGNORECASE
    )
    return html.unescape(match.group(1)).strip() if match else ""


def _cookies_header_for_url(cookies_path: str, url: str) -> str:
    path = os.path.expanduser(str(cookies_path or "").strip())
    if not path:
        return ""
    if not os.path.exists(path):
        raise RuntimeError(f"Configured Threads cookies file does not exist: {path}")

    parsed = urllib.parse.urlparse(url)
    host = (parsed.hostname or "").casefold()
    request_path = parsed.path or "/"
    cookies: list[str] = []

    with open(path, "r", encoding="utf-8", errors="replace") as cookie_file:
        for line in cookie_file:
            line = line.strip()
            if not line or (line.startswith("#") and not line.startswith("#HttpOnly_")):
                continue
            if line.startswith("#HttpOnly_"):
                line = line.removeprefix("#HttpOnly_")
            parts = line.split("\t")
            if len(parts) < 7:
                continue

            domain, _, cookie_path, _, _, name, value = parts[:7]
            domain = domain.lstrip(".").casefold()
            if host != domain and not host.endswith(f".{domain}"):
                continue
            if cookie_path and not request_path.startswith(cookie_path):
                continue
            if name:
                cookies.append(f"{name}={value}")

    return "; ".join(cookies)


def collect_threads_chain(
    url: str,
    *,
    cookies_path: str = "",
    cookie_header: str = "",
    storage_state_path: str = "",
) -> dict[str, Any]:
    """Backward-compatible function used by the FastAPI route."""
    return ThreadsChainCollector(
        cookies_path=cookies_path,
        cookie_header=cookie_header,
        storage_state_path=storage_state_path,
    ).collect(url)
