"""One JSON list per calendar day of URLs the clipper has already accepted.

The key is the note GUID (UUID v5 of the canonical source). A second paste of
the same page or post on the same local day is a duplicate. Callers look the
GUID up and decide whether to skip or download again. The next local day
starts a new file.
"""

from __future__ import annotations

from datetime import date, datetime
import json
from pathlib import Path
import threading
from typing import Optional

from .note_id import canonical_source_id, note_guid_for_source


_lock = threading.RLock()
_directory: Optional[Path] = None


class DuplicateCapture(Exception):
    """The URL's GUID is already on today's capture list."""

    def __init__(self, existing: dict) -> None:
        self.existing = dict(existing)
        self.guid = str(existing.get("guid") or "")
        super().__init__(self.guid)


def configure(data_dir: str) -> None:
    """Store daily lists under ``data_dir/daily-captures``."""
    global _directory
    directory = Path(data_dir).expanduser() / "daily-captures"
    directory.mkdir(parents=True, exist_ok=True)
    with _lock:
        _directory = directory


def lookup(url: str, *, today: Optional[date] = None, now: Optional[datetime] = None) -> Optional[dict]:
    """Today's list entry for the normalized UID of ``url``, or None.

    The URL is reduced to its canonical source id, then to the note GUID.
    A tracking query does not make a second identity.
    """
    identity = _identity(url)
    if identity is None:
        raise ValueError("URL must start with http:// or https://.")
    guid, _source_id = identity
    day = today or (now or datetime.now().astimezone()).date()
    with _lock:
        payload = _read(_path(day))
        for item in payload.get("items") or []:
            if isinstance(item, dict) and str(item.get("guid") or "") == guid:
                return dict(item)
    return None


def claim(url: str, *, today: Optional[date] = None, now: Optional[datetime] = None) -> str:
    """Record ``url`` on today's list and return its GUID.

    Raises ``DuplicateCapture`` when that GUID is already listed for the day.
    ``today`` overrides the calendar day so tests can roll the date forward.
    """
    identity = _identity(url)
    if identity is None:
        raise ValueError("URL must start with http:// or https://.")
    guid, source_id = identity
    moment = now or datetime.now().astimezone()
    day = today or moment.date()
    with _lock:
        path = _path(day)
        payload = _read(path)
        items = payload.get("items")
        if not isinstance(items, list):
            items = []
        for item in items:
            if isinstance(item, dict) and str(item.get("guid") or "") == guid:
                raise DuplicateCapture(item)
        items.append(
            {
                "guid": guid,
                "source_id": source_id,
                "url": str(url or "").strip(),
                "captured_at": moment.isoformat(timespec="seconds"),
            }
        )
        payload["date"] = day.isoformat()
        payload["items"] = items
        _write(path, payload)
    return guid


def _identity(url: str) -> Optional[tuple[str, str]]:
    source_id = canonical_source_id(url)
    if not source_id:
        return None
    return note_guid_for_source(url), source_id


def _path(day: date) -> Path:
    if _directory is None:
        raise RuntimeError("Daily capture list is not configured.")
    return _directory / f"{day.isoformat()}.json"


def _read(path: Path) -> dict:
    if not path.is_file():
        return {"date": path.stem, "items": []}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"date": path.stem, "items": []}
    if not isinstance(payload, dict):
        return {"date": path.stem, "items": []}
    return payload


def _write(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)
