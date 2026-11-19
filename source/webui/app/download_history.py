"""SQLite log of clip downloads for the History page.

One row per clip request once it finishes (completed, failed, or duplicate
cancelled). The database lives at ``<data_dir>/history.sqlite``. Keyword
search matches the UUID, URL, title, kind, origin, status, and request id.
"""

from __future__ import annotations

import json
import sqlite3
import threading
from pathlib import Path
from typing import Any, Optional

_lock = threading.Lock()
_db_path: Optional[Path] = None

TERMINAL_STATUSES = ("completed", "failed", "duplicate_cancelled")
PAGE_SIZES = (25, 50, 100, 200, 500)
DEFAULT_PAGE_SIZE = 100
_MAX_TERMS = 8
_SEARCH_COLUMNS = ("guid", "url", "title", "kind", "origin", "status", "request_id", "message")


def configure(data_dir: str) -> None:
    """Open (and create) the history database under ``data_dir``."""
    global _db_path
    root = Path(data_dir).expanduser()
    root.mkdir(parents=True, exist_ok=True)
    path = root / "history.sqlite"
    with _lock:
        _db_path = path
        with _connect(path) as conn:
            _ensure_schema(conn)


def note(record: dict[str, Any]) -> None:
    """Insert or refresh a finished clip request. In-progress rows are ignored."""
    if _db_path is None:
        return
    status = str(record.get("status") or "")
    if status not in TERMINAL_STATUSES:
        return
    request_id = str(record.get("id") or "").strip()
    if not request_id:
        return
    row = (
        request_id,
        str(record.get("guid") or "")[:80],
        str(record.get("source") or "")[:2000],
        str(record.get("title") or record.get("note_title") or "")[:300],
        str(record.get("kind") or "")[:40],
        str(record.get("origin") or "")[:40],
        status,
        str(record.get("message") or "")[:300],
        str(record.get("created_at") or ""),
        str(record.get("updated_at") or record.get("created_at") or ""),
        str(record.get("datetime") or "")[:80],
    )
    with _lock:
        if _db_path is None:
            return
        with _connect(_db_path) as conn:
            _ensure_schema(conn)
            conn.execute(
                """
                INSERT INTO downloads (
                    request_id, guid, url, title, kind, origin, status, message,
                    created_at, finished_at, content_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(request_id) DO UPDATE SET
                    guid = CASE WHEN excluded.guid != '' THEN excluded.guid ELSE downloads.guid END,
                    url = CASE WHEN excluded.url != '' THEN excluded.url ELSE downloads.url END,
                    title = CASE WHEN excluded.title != '' THEN excluded.title ELSE downloads.title END,
                    kind = excluded.kind,
                    origin = excluded.origin,
                    status = excluded.status,
                    message = excluded.message,
                    created_at = CASE WHEN downloads.created_at != '' THEN downloads.created_at ELSE excluded.created_at END,
                    content_at = CASE WHEN excluded.content_at != '' THEN excluded.content_at ELSE downloads.content_at END
                """,
                row,
            )
            conn.commit()


def backfill_requests(directory: str | Path) -> int:
    """Import finished ``requests/*.json`` files. Safe to run more than once."""
    root = Path(directory)
    if _db_path is None or not root.is_dir():
        return 0
    imported = 0
    for path in sorted(root.glob("*.json")):
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(loaded, dict) or str(loaded.get("status") or "") not in TERMINAL_STATUSES:
            continue
        note(loaded)
        imported += 1
    return imported


def search(query: str = "", *, page: int = 1, page_size: int = DEFAULT_PAGE_SIZE) -> dict[str, Any]:
    """Newest finished downloads first. Every keyword must match some column."""
    size = _page_size(page_size)
    try:
        page_number = max(1, int(page))
    except (TypeError, ValueError):
        page_number = 1
    terms = _terms(query)
    where, params = _where(terms)
    if _db_path is None:
        return _empty(page_number, size)
    with _lock:
        if _db_path is None:
            return _empty(page_number, size)
        with _connect(_db_path) as conn:
            _ensure_schema(conn)
            total = int(conn.execute(f"SELECT COUNT(*) FROM downloads{where}", params).fetchone()[0])
            pages = (total + size - 1) // size if total else 0
            if pages and page_number > pages:
                page_number = pages
            offset = (page_number - 1) * size
            rows = conn.execute(
                f"""
                SELECT request_id, guid, url, title, kind, origin, status, message,
                       created_at, finished_at, content_at
                FROM downloads{where}
                ORDER BY finished_at DESC, request_id DESC
                LIMIT ? OFFSET ?
                """,
                (*params, size, offset),
            ).fetchall()
    return {
        "items": [dict(row) for row in rows],
        "total": total,
        "page": page_number,
        "page_size": size,
        "pages": pages,
        "page_sizes": list(PAGE_SIZES),
    }


def _empty(page: int, size: int) -> dict[str, Any]:
    return {"items": [], "total": 0, "page": page, "page_size": size, "pages": 0, "page_sizes": list(PAGE_SIZES)}


def _page_size(value: Any) -> int:
    try:
        size = int(value)
    except (TypeError, ValueError):
        return DEFAULT_PAGE_SIZE
    if size < 1:
        return DEFAULT_PAGE_SIZE
    return min(size, 500)


def _terms(query: str) -> list[str]:
    terms = []
    for part in str(query or "").split():
        text = part.strip().lower()[:80]
        if text:
            terms.append(text)
        if len(terms) >= _MAX_TERMS:
            break
    return terms


def _where(terms: list[str]) -> tuple[str, list[str]]:
    if not terms:
        return "", []
    clauses = []
    params: list[str] = []
    for term in terms:
        like = f"%{_escape_like(term)}%"
        columns = " OR ".join(f"lower({column}) LIKE ? ESCAPE '\\'" for column in _SEARCH_COLUMNS)
        clauses.append(f"({columns})")
        params.extend([like] * len(_SEARCH_COLUMNS))
    return " WHERE " + " AND ".join(clauses), params


def _escape_like(term: str) -> str:
    return term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _connect(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(path, timeout=5)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def _ensure_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS downloads (
            request_id TEXT PRIMARY KEY,
            guid TEXT NOT NULL DEFAULT '',
            url TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            kind TEXT NOT NULL DEFAULT '',
            origin TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT '',
            message TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL DEFAULT '',
            finished_at TEXT NOT NULL DEFAULT '',
            content_at TEXT NOT NULL DEFAULT ''
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS downloads_finished ON downloads(finished_at DESC, request_id DESC)")
    conn.commit()
