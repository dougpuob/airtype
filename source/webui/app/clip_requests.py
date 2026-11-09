"""One JSON file per clipper request.

The filename is the local time the request was accepted, ``YYYYMMDD-HHMMSS``.
A later request in the same second gets ``-2``, ``-3``, and so on. The file
keeps the result and whether the user has saved it to Obsidian.

A sibling index ``clip-requests-pending.json`` lists request ids that are not
yet saved to Obsidian. ``list_pending`` reads that one file, then loads only
those request records. Saved ids are removed from the index. Rebuild the
index with ``rebuild_pending_index`` when it looks out of sync.

Pending records are cached in memory. Each cached record remembers the file's
``(mtime_ns, size)``; ``list_pending`` only stats the pending files and rereads
the ones that changed. Writes through this module refresh the cache directly.
The serialized list response (plain and gzip) is cached as well and keyed by
an ETag built from those stamps, so an unchanged queue is never re-serialized.
"""

from __future__ import annotations

from datetime import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path
import threading
from typing import Any, Optional


_lock = threading.RLock()
_directory: Optional[Path] = None
_cancel_events: dict[str, threading.Event] = {}

_PENDING_INDEX_NAME = "clip-requests-pending.json"

# Large body fields left out of the queue list. Fetch one record with ``get``
# (``GET /api/clip-requests/{id}``) when the user opens it or saves it.
HEAVY_FIELDS = ("note", "content", "polished_content", "external_content")

_Stamp = tuple[int, int]
# In-memory caches; guarded by ``_lock``.
_pending_ids_cache: Optional[list[str]] = None
_pending_index_stamp: Optional[_Stamp] = None
_record_cache: dict[str, tuple[_Stamp, dict[str, Any]]] = {}
_list_signature: Optional[tuple[tuple[str, _Stamp], ...]] = None
_list_cache: Optional[list[dict[str, Any]]] = None
_list_etag: str = ""
_body_cache: dict[str, bytes] = {}  # "plain" / "gzip" bodies for ``_list_etag``


def configure(data_dir: str) -> None:
    """Store requests under ``data_dir/requests`` and close out interrupted work."""
    global _directory
    root = Path(data_dir).expanduser()
    directory = root / "requests"
    directory.mkdir(parents=True, exist_ok=True)
    with _lock:
        _directory = directory
        _reset_cache_locked()
        if not _pending_index_path().is_file():
            _rebuild_pending_index_locked()
        for request_id in list(_read_pending_ids()):
            record = _read_cached(request_id)
            if not record:
                _remove_pending_id(request_id)
                continue
            if record.get("status") in {"queued", "running"}:
                record["status"] = "failed"
                record["progress"] = 100
                record["message"] = "Failed"
                record["error"] = record.get("error") or "Interrupted when the server restarted"
                record["updated_at"] = _now()
                _write(record)


def create(*, kind: str, source: str, notes: str = "", origin: str = "manual", now: Optional[datetime] = None) -> dict[str, Any]:
    """Create a queued request file and return its public record."""
    current = now or datetime.now().astimezone()
    stamp = current.strftime("%Y%m%d-%H%M%S")
    with _lock:
        request_id = stamp
        suffix = 2
        while _path(request_id).exists():
            request_id = f"{stamp}-{suffix}"
            suffix += 1
        record = {
            "id": request_id,
            "kind": kind,
            "source": source,
            "origin": _clean_origin(origin),
            "notes": _clean_notes(notes),
            "external_content": "",
            "status": "queued",
            "step": 0,
            "progress": 0,
            "message": "Queued",
            "error": "",
            "obsidian_save": "pending",
            "published": False,
            "job_id": "",
            "title": "",
            "content": "",
            "polished_content": "",
            "ai_tags": "",
            "sources": [],
            "tags": [],
            "datetime": "",
            "guid": "",
            "share_url": "",
            "note_title": "",
            "note": "",
            "created_at": current.isoformat(timespec="seconds"),
            "updated_at": current.isoformat(timespec="seconds"),
        }
        _cancel_events[request_id] = threading.Event()
        _write(record)
        _add_pending_id(request_id)
        return dict(record)


def get(request_id: str) -> Optional[dict[str, Any]]:
    with _lock:
        return _read(request_id)


def list_pending() -> list[dict[str, Any]]:
    """Requests the user has not saved to Obsidian, newest first.

    Reads the pending-id index, then loads only those request files. Records
    come from the in-memory cache unless the file changed on disk.
    """
    with _lock:
        records = _list_pending_locked()
        return [dict(record) for record in records]


def slim_record(record: dict[str, Any]) -> dict[str, Any]:
    """Queue-list view of a record: heavy body fields dropped, with flags.

    ``has_note`` / ``has_content`` tell the UI whether Save / preview are
    possible without shipping the text itself.
    """
    slim = {key: value for key, value in record.items() if key not in HEAVY_FIELDS}
    slim["has_note"] = bool(str(record.get("note") or "").strip())
    slim["has_content"] = bool(str(record.get("content") or "").strip())
    slim["summary"] = True
    return slim


def list_pending_slim() -> list[dict[str, Any]]:
    """``list_pending`` without the heavy body fields."""
    with _lock:
        return [slim_record(record) for record in _list_pending_locked()]


def pending_response_body(*, compress: bool = False) -> tuple[str, bytes]:
    """``(etag, body)`` for ``{"requests": list_pending_slim()}`` as JSON bytes.

    The body is cached until the pending list changes, so repeated page loads
    cost a few ``stat`` calls. With ``compress`` the gzip body is returned.
    """
    with _lock:
        records = _list_pending_locked()
        etag = _list_etag
        plain = _body_cache.get("plain")
        if plain is None:
            plain = json.dumps(
                {"requests": [slim_record(record) for record in records]}, ensure_ascii=False, allow_nan=False, separators=(",", ":")
            ).encode("utf-8")
            _body_cache["plain"] = plain
        if not compress:
            return etag, plain
        packed = _body_cache.get("gzip")
        if packed is None:
            packed = gzip.compress(plain, compresslevel=6, mtime=0)
            _body_cache["gzip"] = packed
        return etag, packed


def warm_cache() -> None:
    """Load pending records and build the cached response bodies."""
    try:
        pending_response_body(compress=True)
    except Exception:
        pass


def rebuild_pending_index() -> list[str]:
    """Rescan every request file and rewrite the pending-id index.

    Use when the index looks out of sync with the request files. Also drops
    every in-memory cache so the next list rereads from disk.
    """
    with _lock:
        _reset_cache_locked()
        return _rebuild_pending_index_locked()


def update(request_id: str, **changes: Any) -> Optional[dict[str, Any]]:
    with _lock:
        record = _read(request_id)
        if not record:
            return None
        if "step" not in changes:
            changes["step"] = infer_step(
                str(changes.get("kind") or record.get("kind") or ""),
                str(changes.get("status") or record.get("status") or ""),
                str(changes.get("message") or record.get("message") or ""),
                current_step=int(record.get("step") or 0),
            )
        record.update(changes)
        record["updated_at"] = _now()
        _write(record)
        if record.get("obsidian_save") == "complete":
            _remove_pending_id(request_id)
        else:
            _add_pending_id(request_id)
        return dict(record)


def mark_saved(request_id: str) -> Optional[dict[str, Any]]:
    """Record that the user saved this completed note to Obsidian."""
    with _lock:
        record = _read(request_id)
        if not record:
            return None
        if record.get("status") != "completed":
            return dict(record)
        if record.get("obsidian_save") == "complete":
            return dict(record)
        record["obsidian_save"] = "complete"
        record["updated_at"] = _now()
        _write(record)
        _remove_pending_id(request_id)
        return dict(record)


def export_fingerprint(record: dict[str, Any]) -> str:
    """Hash the exported note fields. ``updated_at`` is only second-resolution."""
    raw_tags = record.get("tags") if isinstance(record.get("tags"), list) else []
    payload = {
        "note": str(record.get("note") or ""),
        "note_title": str(record.get("note_title") or ""),
        "tags": [str(item) for item in raw_tags],
        "title": str(record.get("title") or ""),
    }
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def mark_exported_note(
    request_id: str,
    *,
    updated_at: Optional[str],
    content_sha256: Optional[str],
) -> str:
    """Mark one exported note saved when it still matches the export snapshot.

    Returns ``saved``, ``missing``, ``not_completed``, or ``changed``.
    Already-saved notes return ``saved`` without rewriting the record, so a
    duplicate completion does not bump ``updated_at`` or touch other notes.
    A ``None`` snapshot (exports created before revisions were stored) keeps
    the older behavior: any completed note in that export may be marked.
    """
    with _lock:
        record = _read(request_id)
        if not record:
            return "missing"
        if record.get("obsidian_save") == "complete":
            return "saved"
        if record.get("status") != "completed":
            return "not_completed"
        if updated_at is not None and str(record.get("updated_at") or "") != updated_at:
            return "changed"
        if content_sha256 is not None and export_fingerprint(record) != content_sha256:
            return "changed"
        record["obsidian_save"] = "complete"
        record["updated_at"] = _now()
        _write(record)
        _remove_pending_id(request_id)
        return "saved"


def request_cancel(request_id: str) -> Optional[dict[str, Any]]:
    """Ask a worker to stop. A request that has not started is failed immediately."""
    with _lock:
        event = _cancel_events.get(request_id)
        if event is None:
            event = threading.Event()
            _cancel_events[request_id] = event
        event.set()
        record = _read(request_id)
        if not record:
            return None
        if record.get("status") == "queued":
            record["status"] = "failed"
            record["progress"] = 100
            record["message"] = "Failed"
            record["error"] = "Stopped by user"
            record["published"] = True
            record["updated_at"] = _now()
            _write(record)
        return dict(record)


def delete(request_id: str) -> bool:
    """Remove a request file. Later worker updates cannot recreate it."""
    with _lock:
        event = _cancel_events.get(request_id)
        if event is None:
            event = threading.Event()
            _cancel_events[request_id] = event
        event.set()
        path = _path(request_id)
        if not path.is_file():
            _remove_pending_id(request_id)
            return False
        path.unlink()
        _record_cache.pop(request_id, None)
        _invalidate_list_locked()
        _remove_pending_id(request_id)
        return True


def infer_step(kind: str, status: str, message: str, current_step: int = 0) -> int:
    """Stepper index for a clip. Completed means every step is done."""
    if status == "completed":
        return 100
    if status == "failed":
        return current_step
    text = f"{message} {status}".lower()
    if kind == "voice":
        if "tag" in text or "標籤" in message:
            return 3
        if "title" in text or "article" in text or "標題" in message or "潤稿" in message:
            return 2
        if "transcri" in text or "segment" in text:
            return 1
        return 0
    if kind == "post":
        if "tag" in text or "標籤" in message:
            return 4
        if "title" in text or "標題" in message:
            return 3
        if "polish" in text or "潤稿" in message:
            return 2
        if "photo" in text or "照片" in message:
            return 1
        return 0
    if "tag" in text or "標籤" in message:
        return 3
    if "title" in text or "標題" in message:
        return 2
    if "polish" in text or "潤稿" in message:
        return 1
    return 0


def is_cancelled(request_id: str) -> bool:
    event = _cancel_events.get(request_id)
    return bool(event and event.is_set())


def _directory_path() -> Path:
    if _directory is None:
        raise RuntimeError("Clip requests are not configured")
    return _directory


def _data_root() -> Path:
    return _directory_path().parent


def _pending_index_path() -> Path:
    return _data_root() / _PENDING_INDEX_NAME


def _path(request_id: str) -> Path:
    if "/" in request_id or "\\" in request_id or request_id in {"", ".", ".."}:
        raise ValueError("Invalid clip request id")
    return _directory_path() / f"{request_id}.json"


def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _clean_notes(value: str) -> str:
    """Keep a short personal memo. It is not sent to the polish / title / tag models."""
    text = str(value or "").replace("\r\n", "\n").replace("\r", "\n")
    return text[:2000].rstrip()


def _clean_origin(value: str) -> str:
    """How the request entered the queue: Clipper click vs Watching sync."""
    return "watching" if str(value or "").strip().lower() == "watching" else "manual"


def _write(record: dict[str, Any]) -> None:
    request_id = str(record["id"])
    path = _path(request_id)
    path.write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
    stamp = _file_stamp(path)
    if stamp is None:
        _record_cache.pop(request_id, None)
    else:
        _record_cache[request_id] = (stamp, dict(record))
    _invalidate_list_locked()


def _read(request_id: str) -> Optional[dict[str, Any]]:
    path = _path(request_id)
    if not path.is_file():
        return None
    loaded = json.loads(path.read_text(encoding="utf-8"))
    return loaded if isinstance(loaded, dict) else None


def _file_stamp(path: Path) -> Optional[_Stamp]:
    try:
        info = os.stat(path)
    except OSError:
        return None
    return (info.st_mtime_ns, info.st_size)


def _read_cached(request_id: str) -> Optional[dict[str, Any]]:
    """Cached record (not a copy). Rereads the file when its stamp changed."""
    path = _path(request_id)
    stamp = _file_stamp(path)
    if stamp is None:
        _record_cache.pop(request_id, None)
        return None
    cached = _record_cache.get(request_id)
    if cached is not None and cached[0] == stamp:
        return cached[1]
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        _record_cache.pop(request_id, None)
        return None
    if not isinstance(loaded, dict):
        _record_cache.pop(request_id, None)
        return None
    _record_cache[request_id] = (stamp, loaded)
    return loaded


def _reset_cache_locked() -> None:
    global _pending_ids_cache, _pending_index_stamp
    _pending_ids_cache = None
    _pending_index_stamp = None
    _record_cache.clear()
    _invalidate_list_locked()


def _invalidate_list_locked() -> None:
    global _list_signature, _list_cache, _list_etag
    _list_signature = None
    _list_cache = None
    _list_etag = ""
    _body_cache.clear()


def _list_pending_locked() -> list[dict[str, Any]]:
    """Cached, sorted pending records (shared objects; callers copy)."""
    global _list_signature, _list_cache, _list_etag
    ids = _read_pending_ids()
    stamps: list[tuple[str, _Stamp]] = []
    for request_id in ids:
        stamp = _file_stamp(_path(request_id))
        stamps.append((request_id, stamp or (-1, -1)))
    signature = tuple(stamps)
    if _list_cache is not None and signature == _list_signature:
        return _list_cache

    records: list[dict[str, Any]] = []
    stale: list[str] = []
    for request_id in ids:
        record = _read_cached(request_id)
        if not record or record.get("obsidian_save") == "complete":
            stale.append(request_id)
            continue
        records.append(record)
    for request_id in stale:
        _remove_pending_id(request_id)
    stale_set = set(stale)
    if stale_set:
        # Index changed; keep the signature for the remaining ids only.
        signature = tuple(item for item in signature if item[0] not in stale_set)
    pending = set(ids) - stale_set
    for request_id in list(_record_cache):
        if request_id not in pending:
            del _record_cache[request_id]
    records.sort(key=lambda record: str(record.get("created_at") or ""), reverse=True)
    _body_cache.clear()
    _list_cache = records
    _list_signature = signature
    digest = hashlib.sha1(repr(signature).encode("utf-8")).hexdigest()[:20]
    _list_etag = f'W/"crs-{digest}"'
    return records


def _read_all() -> list[dict[str, Any]]:
    records = []
    for path in _directory_path().glob("*.json"):
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(loaded, dict) and loaded.get("id"):
            records.append(loaded)
    return records


def _read_pending_ids() -> list[str]:
    global _pending_ids_cache, _pending_index_stamp
    path = _pending_index_path()
    stamp = _file_stamp(path)
    if stamp is None:
        return _rebuild_pending_index_locked()
    if _pending_ids_cache is not None and stamp == _pending_index_stamp:
        return list(_pending_ids_cache)
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return _rebuild_pending_index_locked()
    if isinstance(loaded, list):
        ids = [str(item) for item in loaded if str(item or "").strip()]
    elif isinstance(loaded, dict):
        raw = loaded.get("ids")
        if not isinstance(raw, list):
            return _rebuild_pending_index_locked()
        ids = [str(item) for item in raw if str(item or "").strip()]
    else:
        return _rebuild_pending_index_locked()
    # newest first when ids were appended at the front
    _pending_ids_cache = list(ids)
    _pending_index_stamp = stamp
    return ids


def _write_pending_ids(ids: list[str]) -> None:
    # Keep newest ids first; drop duplicates while preserving order.
    seen: set[str] = set()
    ordered: list[str] = []
    for request_id in ids:
        if request_id in seen:
            continue
        seen.add(request_id)
        ordered.append(request_id)
    global _pending_ids_cache, _pending_index_stamp
    path = _pending_index_path()
    path.write_text(json.dumps({"ids": ordered}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    _pending_ids_cache = list(ordered)
    _pending_index_stamp = _file_stamp(path)
    _invalidate_list_locked()


def _add_pending_id(request_id: str) -> None:
    ids = _read_pending_ids()
    if request_id in ids:
        return
    _write_pending_ids([request_id, *ids])


def _remove_pending_id(request_id: str) -> None:
    ids = _read_pending_ids()
    if request_id not in ids:
        return
    _write_pending_ids([item for item in ids if item != request_id])


def _rebuild_pending_index_locked() -> list[str]:
    ids = [
        str(record["id"])
        for record in _read_all()
        if record.get("id") and record.get("obsidian_save") != "complete"
    ]
    ids.sort(reverse=True)
    _write_pending_ids(ids)
    return ids
