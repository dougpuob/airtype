"""Scheduled checks of Threads profiles ("Watching" tab).

The watch list (who to monitor, how often, and whether it is enabled) is stored
in ``config.json`` under ``webui.watches`` so it survives a process restart
even when the data directory is new. Each target also has a runtime file in
``<data_dir>/watches/<target-id>.json``: the last check and the posts already
seen (metadata only, no post body). The scheduler in main.py calls
:func:`run_check` for due targets; new posts are handed to a ``queue_fn`` that
submits them to the Obsidian Clipper queue.

Fetching uses the public profile page: Threads server-renders the first page
of the profile timeline as JSON in ``script[data-sjs]`` blocks. That is only
the most recent few threads (typically 4-10), which is enough for a check
every 15+ minutes. When the anonymous page has no posts and a saved Threads
login exists, the request is retried with those cookies.
"""

from __future__ import annotations

import json
import os
import re
import threading
import urllib.parse
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Optional

from .post_weaver import _DataSjsParser, _caption_text

MIN_INTERVAL_MINUTES = 15
DEFAULT_INTERVAL_MINUTES = 60
MAX_INTERVAL_MINUTES = 7 * 24 * 60
MAX_LOG_POSTS = 500

_USERNAME = re.compile(r"^[A-Za-z0-9._]{1,30}$")
_THREADS_HOSTS = {"threads.com", "www.threads.com", "threads.net", "www.threads.net"}
_HEADERS = {
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131 Safari/537.36"
    ),
}
_lock = threading.RLock()


class WatchFetchError(RuntimeError):
    """A check failed in a way the user should see (code + message)."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


# --------------------------------------------------------------------------- #
# Input normalisation
# --------------------------------------------------------------------------- #

def normalize_threads_username(value: str) -> str:
    """Accept ``@name``, ``name`` or a profile/post URL; return ``name``."""
    text = str(value or "").strip()
    if not text:
        raise ValueError("Enter a Threads username or profile URL.")
    if re.match(r"^(https?://)?(www\.)?threads\.(com|net)(/|$)", text, re.I):
        if not re.match(r"^https?://", text, re.I):
            text = "https://" + text
        parsed = urllib.parse.urlparse(text)
        if (parsed.hostname or "").lower() not in _THREADS_HOSTS:
            raise ValueError("Only threads.com / threads.net URLs are supported.")
        first = urllib.parse.unquote(parsed.path).strip("/").split("/")[0]
        if not first.startswith("@"):
            raise ValueError("Could not find an @username in the URL, for example https://www.threads.com/@name")
        text = first
    name = text.lstrip("@").strip()
    if not _USERNAME.match(name):
        raise ValueError(f"“{value}” is not a valid Threads username (letters, numbers, underscores, and periods only).")
    return name.lower()


def profile_url(username: str) -> str:
    return f"https://www.threads.com/@{username}"


def clamp_interval(minutes: Any) -> int:
    try:
        value = int(minutes)
    except (TypeError, ValueError):
        value = DEFAULT_INTERVAL_MINUTES
    return max(MIN_INTERVAL_MINUTES, min(value, MAX_INTERVAL_MINUTES))


# --------------------------------------------------------------------------- #
# Parsing the profile page
# --------------------------------------------------------------------------- #

def _iter_thread_heads(value: Any) -> Iterable[dict[str, Any]]:
    """First post of every ``thread_items`` list (the thread's head post)."""
    stack = [value]
    while stack:
        current = stack.pop()
        if isinstance(current, dict):
            items = current.get("thread_items")
            if isinstance(items, list) and items:
                head = items[0].get("post") if isinstance(items[0], dict) else None
                if isinstance(head, dict):
                    yield head
            stack.extend(reversed(list(current.values())))
        elif isinstance(current, list):
            stack.extend(reversed(current))


def _media_counts(post: dict[str, Any]) -> tuple[int, int]:
    carousel = post.get("carousel_media")
    items = carousel if isinstance(carousel, list) and carousel else [post]
    images = videos = 0
    for item in items:
        if not isinstance(item, dict):
            continue
        if isinstance(item.get("video_versions"), list) and item["video_versions"]:
            videos += 1
        elif isinstance(item.get("image_versions2"), dict) and (item["image_versions2"].get("candidates") or []):
            images += 1
    return images, videos


def _title(text: str) -> str:
    for line in text.splitlines():
        line = line.strip()
        if line:
            return line[:80]
    return ""


def post_summary(post: dict[str, Any], username: str) -> Optional[dict[str, Any]]:
    user = post.get("user") if isinstance(post.get("user"), dict) else {}
    author = str(user.get("username") or "").lower()
    code = str(post.get("code") or "").strip()
    if not code or author != username.lower():
        return None
    text = _caption_text(post.get("caption"))
    images, videos = _media_counts(post)
    taken_at = post.get("taken_at")
    created = (
        datetime.fromtimestamp(int(taken_at), tz=timezone.utc).astimezone().isoformat()
        if isinstance(taken_at, (int, float)) and taken_at
        else None
    )
    info = post.get("text_post_app_info") if isinstance(post.get("text_post_app_info"), dict) else {}
    pinned = info.get("pinned_post_info") if isinstance(info.get("pinned_post_info"), dict) else {}
    return {
        "code": code,
        "url": f"https://www.threads.com/@{author}/post/{code}",
        "title": _title(text),
        "post_created_at": created,
        "text_length": len(text),
        "image_count": images,
        "video_count": videos,
        "pinned": bool(pinned.get("is_pinned_to_profile")),
    }


def parse_profile_page(page: str, username: str) -> dict[str, Any]:
    """Posts by ``username`` found in a profile page, newest first."""
    username = username.lower()
    payloads = _DataSjsParser.payloads(page)
    posts: dict[str, dict[str, Any]] = {}
    for payload in payloads:
        for head in _iter_thread_heads(payload):
            summary = post_summary(head, username)
            if summary and summary["code"] not in posts:
                posts[summary["code"]] = summary
    ordered = sorted(posts.values(), key=lambda p: p.get("post_created_at") or "", reverse=True)
    profile_seen = f'"username":"{username}"' in page.lower()
    return {"posts": ordered, "profile_seen": profile_seen, "payloads": len(payloads)}


# --------------------------------------------------------------------------- #
# Fetching
# --------------------------------------------------------------------------- #

def _http_get(url: str, cookie_header: str, timeout: int) -> tuple[int, str, str]:
    headers = dict(_HEADERS)
    if cookie_header:
        headers["Cookie"] = cookie_header
    try:
        from curl_cffi import requests as curl_requests

        response = curl_requests.get(url, headers=headers, impersonate="chrome131", timeout=timeout, allow_redirects=True)
        return response.status_code, str(response.url), response.text
    except ImportError:
        import urllib.error
        import urllib.request

        request = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.status, response.geturl(), response.read(5_000_000).decode("utf-8", "replace")
        except urllib.error.HTTPError as error:
            return error.code, url, ""


def fetch_profile_posts(
    username: str,
    *,
    cookie_header_fn: Optional[Callable[[str], str]] = None,
    timeout: int = 20,
    http_get: Callable[[str, str, int], tuple[int, str, str]] = _http_get,
) -> dict[str, Any]:
    """Recent posts on a Threads profile. Raises WatchFetchError."""
    url = profile_url(username)
    attempts = [("anonymous", "")]
    cookie = cookie_header_fn(url) if cookie_header_fn else ""
    if cookie:
        attempts.append(("cookies", cookie))

    errors: list[dict[str, Any]] = []
    for mode, cookie_value in attempts:
        last: dict[str, Any] = {}
        try:
            status, final_url, page = http_get(url, cookie_value, timeout)
        except Exception as error:  # network error
            last = {"code": "network", "message": f"Could not reach Threads: {error}"}
            errors.append(last)
            continue
        if status == 404:
            last = {"code": "not_found", "message": f"Account @{username} was not found (HTTP 404)."}
            errors.append(last)
            continue
        if status >= 400:
            last = {"code": "http_error", "message": f"Threads returned HTTP {status}."}
            errors.append(last)
            continue
        if "/login" in urllib.parse.urlparse(final_url).path:
            last = {"code": "login_wall", "message": f"Threads sent @{username} to the login page: the account is usually missing or misspelled. For a private or restricted account, provide signed-in Threads cookies (yt-dlp cookies in Settings, or an existing storage-state.json)."}
            errors.append(last)
            continue
        parsed = parse_profile_page(page, username)
        if parsed["posts"]:
            return {"username": username, "profile_url": url, "fetch": mode, "posts": parsed["posts"]}
        if not parsed["profile_seen"]:
            last = {"code": "not_found", "message": f"The page has no profile for @{username}. The account may be missing, renamed, or private."}
        else:
            last = {
                "code": "no_posts",
                "message": "The account exists, but the page has no public posts (it may have none, be private, or require login).",
            }
        errors.append(last)
    priority = ["not_found", "no_posts", "login_wall", "http_error", "network"]
    errors = [e for e in errors if e] or [{}]
    best = min(errors, key=lambda e: priority.index(e["code"]) if e.get("code") in priority else len(priority))
    raise WatchFetchError(best.get("code", "unknown"), best.get("message", "Could not read the Threads profile."))


# --------------------------------------------------------------------------- #
# Diffing
# --------------------------------------------------------------------------- #

def seen_codes(target: dict[str, Any]) -> set[str]:
    return {str(p.get("code")) for p in target.get("posts") or [] if p.get("code")}


def find_new_posts(fetched: list[dict[str, Any]], seen: set[str]) -> list[dict[str, Any]]:
    """Posts not seen before, oldest first (so the queue keeps post order)."""
    fresh = [p for p in fetched if p.get("code") and p["code"] not in seen]
    return sorted(fresh, key=lambda p: p.get("post_created_at") or "")


# --------------------------------------------------------------------------- #
# Storage
# --------------------------------------------------------------------------- #

# Settings that must survive a restart. Runtime fields (posts, last check,
# baseline) stay in the data-dir file and are rebuilt if that file is gone.
WATCH_CONFIG_FIELDS = (
    "id",
    "site",
    "username",
    "profile_url",
    "label",
    "interval_minutes",
    "enabled",
    "initial_queue_latest",
    "created_at",
)


def watch_config_entry(target: dict[str, Any]) -> dict[str, Any]:
    """The part of a watch that belongs in config.json."""
    return {
        "id": str(target.get("id") or ""),
        "site": str(target.get("site") or "threads"),
        "username": str(target.get("username") or ""),
        "profile_url": str(target.get("profile_url") or ""),
        "label": str(target.get("label") or ""),
        "interval_minutes": clamp_interval(target.get("interval_minutes")),
        "enabled": bool(target.get("enabled")),
        "initial_queue_latest": max(0, min(int(target.get("initial_queue_latest") or 0), 10)),
        "created_at": str(target.get("created_at") or ""),
    }


def _target_from_config(entry: dict[str, Any]) -> dict[str, Any]:
    """A watch restored from config, with no remembered posts yet."""
    target = new_target(
        str(entry.get("username") or ""),
        label=str(entry.get("label") or ""),
        interval_minutes=entry.get("interval_minutes"),
        enabled=bool(entry.get("enabled", True)),
        queue_latest=int(entry.get("initial_queue_latest") or 0),
    )
    target["id"] = str(entry.get("id") or target["id"])
    if entry.get("site"):
        target["site"] = str(entry["site"])
    if entry.get("profile_url"):
        target["profile_url"] = str(entry["profile_url"])
    if entry.get("created_at"):
        target["created_at"] = str(entry["created_at"])
    return target


def _apply_config(target: dict[str, Any], entry: dict[str, Any]) -> dict[str, Any]:
    """Settings in config win. Empty text in an older config does not wipe the runtime file."""
    overlay = {key: value for key, value in entry.items() if value not in ("", None)}
    return {**target, **watch_config_entry({**target, **overlay})}


class WatchStore:
    def __init__(self, data_dir: str, config_path: str | Path | None = None) -> None:
        self.dir = Path(data_dir) / "watches"
        self.config_path = Path(config_path) if config_path else None

    def _path(self, target_id: str) -> Path:
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", target_id or ""):
            raise ValueError("Invalid watch id")
        return self.dir / f"{target_id}.json"

    def _read_files(self) -> list[dict[str, Any]]:
        if not self.dir.exists():
            return []
        items = []
        for path in sorted(self.dir.glob("*.json")):
            try:
                loaded = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if isinstance(loaded, dict) and loaded.get("id"):
                items.append(loaded)
        return items

    def _read_document(self) -> dict[str, Any]:
        if self.config_path is None or not self.config_path.exists():
            return {}
        try:
            loaded = json.loads(self.config_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return loaded if isinstance(loaded, dict) else {}

    def _read_config_entries(self) -> list[dict[str, Any]]:
        if self.config_path is None:
            return []
        webui = self._read_document().get("webui")
        watches = webui.get("watches") if isinstance(webui, dict) else None
        if not isinstance(watches, list):
            return []
        entries = []
        for item in watches:
            if isinstance(item, dict) and item.get("id") and item.get("username"):
                entries.append(watch_config_entry(item))
        return entries

    def _write_config_entries(self, entries: list[dict[str, Any]]) -> None:
        if self.config_path is None:
            return
        document = self._read_document()
        webui = document.get("webui")
        if not isinstance(webui, dict):
            webui = {}
            document["webui"] = webui
        webui["watches"] = [watch_config_entry(entry) for entry in entries if entry.get("id")]
        self.config_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.config_path.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.replace(temporary, self.config_path)

    def _merged(self, files: list[dict[str, Any]], entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
        if self.config_path is None:
            return sorted(files, key=lambda t: t.get("created_at") or "")
        by_id = {str(item.get("id")): item for item in files}
        merged: list[dict[str, Any]] = []
        seen: set[str] = set()
        for entry in entries:
            target_id = str(entry["id"])
            seen.add(target_id)
            runtime = by_id.get(target_id)
            merged.append(_apply_config(runtime, entry) if runtime else _target_from_config(entry))
        # A file written before config support is adopted into the list.
        adopted = False
        for runtime in files:
            target_id = str(runtime.get("id") or "")
            if target_id and target_id not in seen:
                merged.append(runtime)
                entries.append(watch_config_entry(runtime))
                adopted = True
        if adopted:
            self._write_config_entries(entries)
        return sorted(merged, key=lambda t: t.get("created_at") or "")

    def list(self) -> list[dict[str, Any]]:
        with _lock:
            return self._merged(self._read_files(), self._read_config_entries())

    def get(self, target_id: str) -> Optional[dict[str, Any]]:
        with _lock:
            path = self._path(target_id)
            runtime = None
            if path.exists():
                try:
                    loaded = json.loads(path.read_text(encoding="utf-8"))
                    runtime = loaded if isinstance(loaded, dict) else None
                except (OSError, ValueError):
                    runtime = None
            entry = next((item for item in self._read_config_entries() if item.get("id") == target_id), None)
            if runtime and entry:
                return _apply_config(runtime, entry)
            if runtime:
                return runtime
            if entry:
                return _target_from_config(entry)
            return None

    def save(self, target: dict[str, Any]) -> dict[str, Any]:
        with _lock:
            self.dir.mkdir(parents=True, exist_ok=True)
            path = self._path(target["id"])
            tmp = path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(target, ensure_ascii=False, indent=2), encoding="utf-8")
            os.replace(tmp, path)
            if self.config_path is not None:
                entry = watch_config_entry(target)
                entries = self._read_config_entries()
                current = next((item for item in entries if item.get("id") == target["id"]), None)
                if current != entry:
                    entries = [item for item in entries if item.get("id") != target["id"]]
                    entries.append(entry)
                    self._write_config_entries(entries)
            return target

    def delete(self, target_id: str) -> bool:
        with _lock:
            path = self._path(target_id)
            existed = path.exists()
            if existed:
                path.unlink()
            if self.config_path is None:
                return existed
            entries = self._read_config_entries()
            kept = [item for item in entries if item.get("id") != target_id]
            removed = len(kept) != len(entries)
            if removed:
                self._write_config_entries(kept)
            return existed or removed

    def find_by_username(self, username: str) -> Optional[dict[str, Any]]:
        for target in self.list():
            if target.get("username") == username:
                return target
        return None


def new_target(username: str, *, label: str = "", interval_minutes: Any = DEFAULT_INTERVAL_MINUTES,
               enabled: bool = True, queue_latest: int = 0, now: Optional[datetime] = None) -> dict[str, Any]:
    current = (now or datetime.now(timezone.utc)).astimezone()
    return {
        "id": f"threads-{username.replace('.', '_')}-{uuid.uuid4().hex[:6]}",
        "site": "threads",
        "username": username,
        "profile_url": profile_url(username),
        "label": label.strip() or f"@{username}",
        "interval_minutes": clamp_interval(interval_minutes),
        "enabled": bool(enabled),
        "initial_queue_latest": max(0, min(int(queue_latest or 0), 10)),
        "baseline_done": False,
        "created_at": current.isoformat(timespec="seconds"),
        "updated_at": current.isoformat(timespec="seconds"),
        "last_checked_at": None,
        "next_check_at": current.isoformat(timespec="seconds"),
        "last_result": None,
        "posts": [],
    }


def schedule_next(target: dict[str, Any], now: datetime) -> None:
    target["next_check_at"] = (now + timedelta(minutes=clamp_interval(target.get("interval_minutes")))).isoformat(timespec="seconds")


def is_due(target: dict[str, Any], now: datetime) -> bool:
    if not target.get("enabled"):
        return False
    due = target.get("next_check_at")
    if not due:
        return True
    try:
        return datetime.fromisoformat(str(due)) <= now
    except ValueError:
        return True


# --------------------------------------------------------------------------- #
# One check
# --------------------------------------------------------------------------- #

def run_check(
    target: dict[str, Any],
    *,
    fetch_fn: Callable[[str], dict[str, Any]],
    queue_fn: Callable[[str], dict[str, Any]],
    now: Optional[datetime] = None,
    queue: bool = True,
) -> dict[str, Any]:
    """Fetch, diff and (optionally) queue new posts. Mutates and returns target.

    The very first successful check records every post as baseline and only
    queues ``initial_queue_latest`` of the newest ones. With ``queue=False``
    (the "test" button) nothing is queued or recorded: the result just shows
    what is there and which posts would be new.
    """
    current = (now or datetime.now(timezone.utc)).astimezone()
    stamp = current.isoformat(timespec="seconds")
    result: dict[str, Any] = {"checked_at": stamp, "ok": False, "dry_run": not queue}
    try:
        fetched = fetch_fn(target["username"])
    except WatchFetchError as error:
        result.update(code=error.code, message=str(error), posts_found=0, new_posts=0, latest=[])
        return _finish(target, result, current, queue)
    except Exception as error:
        result.update(code="unknown", message=f"Check failed: {error}", posts_found=0, new_posts=0, latest=[])
        return _finish(target, result, current, queue)

    posts = fetched.get("posts") or []
    seen = seen_codes(target)
    fresh = find_new_posts(posts, seen)
    result.update(
        ok=True,
        code="ok",
        fetch=fetched.get("fetch"),
        posts_found=len(posts),
        latest=[{**p, "seen": p["code"] in seen} for p in posts[:10]],
    )
    if not queue:
        new_count = 0 if not target.get("baseline_done") else len(fresh)
        result.update(new_posts=new_count, message=_test_message(target, posts, fresh))
        return _finish(target, result, current, queue)

    queued = 0
    failures: list[str] = []
    if not target.get("baseline_done"):
        latest_n = int(target.get("initial_queue_latest") or 0)
        to_queue = {p["code"] for p in sorted(posts, key=lambda p: p.get("post_created_at") or "", reverse=True)[:latest_n]}
        for post in fresh:
            entry = _log_entry(post, stamp, baseline=post["code"] not in to_queue)
            if post["code"] in to_queue:
                queued += _queue_into(entry, queue_fn, failures)
            target.setdefault("posts", []).append(entry)
        target["baseline_done"] = True
        result["message"] = f"First check: found {len(posts)} posts and recorded a baseline" + (
            f", queued the latest {queued}" if queued else ", nothing queued"
        )
    else:
        for post in fresh:
            entry = _log_entry(post, stamp, baseline=False)
            queued += _queue_into(entry, queue_fn, failures)
            target.setdefault("posts", []).append(entry)
        result["message"] = f"Found {len(posts)} posts, {len(fresh)} new" + (f", queued {queued}" if fresh else "")
    if failures:
        result["ok"] = False
        result["code"] = "queue_failed"
        result["message"] += f"; {len(failures)} failed to queue: {failures[0]}"
    result["new_posts"] = queued
    target["posts"] = (target.get("posts") or [])[-MAX_LOG_POSTS:]
    return _finish(target, result, current, queue)


def _test_message(target: dict[str, Any], posts: list[dict[str, Any]], fresh: list[dict[str, Any]]) -> str:
    if not target.get("baseline_done"):
        return f"Settings look good: found {len(posts)} posts. The first real check will record them as a baseline and will not queue them."
    return f"Settings look good: found {len(posts)} posts, {len(fresh)} not processed yet (test will not queue them)."


def _log_entry(post: dict[str, Any], stamp: str, *, baseline: bool) -> dict[str, Any]:
    return {
        "code": post["code"],
        "url": post["url"],
        "title": post.get("title") or "",
        "post_created_at": post.get("post_created_at"),
        "discovered_at": stamp,
        "queued_at": None,
        "text_length": post.get("text_length", 0),
        "image_count": post.get("image_count", 0),
        "video_count": post.get("video_count", 0),
        "pinned": post.get("pinned", False),
        "baseline": baseline,
        "clip_request_id": None,
        "status": "baseline" if baseline else "pending",
        "error": "",
    }


def _queue_into(entry: dict[str, Any], queue_fn: Callable[[str], dict[str, Any]], failures: list[str]) -> int:
    try:
        record = queue_fn(entry["url"])
    except Exception as error:
        entry["status"] = "queue_failed"
        entry["error"] = str(error)[:300]
        failures.append(str(error)[:120])
        return 0
    if record.get("status") == "duplicate_cancelled" or record.get("duplicate") == "cancelled":
        entry["status"] = "duplicate"
        entry["error"] = str(record.get("message") or record.get("error") or "Duplicate cancelled")[:300]
        entry["clip_request_id"] = record.get("id")
        return 0
    entry["clip_request_id"] = record.get("id")
    entry["queued_at"] = record.get("created_at") or datetime.now().astimezone().isoformat(timespec="seconds")
    entry["status"] = "queued"
    entry["baseline"] = False
    return 1


def _finish(target: dict[str, Any], result: dict[str, Any], now: datetime, queue: bool) -> dict[str, Any]:
    if queue:
        target["last_checked_at"] = result["checked_at"]
        target["last_result"] = {k: v for k, v in result.items() if k != "latest"}
        target["updated_at"] = result["checked_at"]
        schedule_next(target, now)
    target["_check"] = result
    return target
