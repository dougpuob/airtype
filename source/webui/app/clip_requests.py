"""One JSON file per clipper request.

The filename is the local time the request was accepted, ``YYYYMMDD-HHMMSS``.
A later request in the same second gets ``-2``, ``-3``, and so on. The file
keeps the result and whether the user has saved it to Obsidian.
"""

from __future__ import annotations

from datetime import datetime
import json
from pathlib import Path
import threading
from typing import Any, Optional


_lock = threading.RLock()
_directory: Optional[Path] = None
_cancel_events: dict[str, threading.Event] = {}


def configure(data_dir: str) -> None:
    """Store requests under ``data_dir/requests`` and close out interrupted work."""
    global _directory
    directory = Path(data_dir).expanduser() / "requests"
    directory.mkdir(parents=True, exist_ok=True)
    with _lock:
        _directory = directory
        for record in _read_all():
            if record.get("status") in {"queued", "running"}:
                record["status"] = "failed"
                record["progress"] = 100
                record["message"] = "Failed"
                record["error"] = record.get("error") or "Interrupted when the server restarted"
                record["updated_at"] = _now()
                _write(record)


def create(*, kind: str, source: str, notes: str = "", now: Optional[datetime] = None) -> dict[str, Any]:
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
            "notes": _clean_notes(notes),
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
        return dict(record)


def get(request_id: str) -> Optional[dict[str, Any]]:
    with _lock:
        return _read(request_id)


def list_pending() -> list[dict[str, Any]]:
    """Requests the user has not saved to Obsidian, newest first."""
    with _lock:
        records = [record for record in _read_all() if record.get("obsidian_save") != "complete"]
    records.sort(key=lambda record: str(record.get("created_at") or ""), reverse=True)
    return records


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
        return dict(record)


def mark_saved(request_id: str) -> Optional[dict[str, Any]]:
    """Record that the user saved this completed note to Obsidian."""
    with _lock:
        record = _read(request_id)
        if not record:
            return None
        if record.get("status") != "completed":
            return dict(record)
        record["obsidian_save"] = "complete"
        record["updated_at"] = _now()
        _write(record)
        return dict(record)


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
            return False
        path.unlink()
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


def _write(record: dict[str, Any]) -> None:
    path = _path(str(record["id"]))
    path.write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")


def _read(request_id: str) -> Optional[dict[str, Any]]:
    path = _path(request_id)
    if not path.is_file():
        return None
    loaded = json.loads(path.read_text(encoding="utf-8"))
    return loaded if isinstance(loaded, dict) else None


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
