"""Temporary Obsidian import manifests for the macOS Local App.

WebUI creates one JSON file per export. The Local App downloads it via
``airtype://obsidian-import?url=…``, writes notes into the vault, then POSTs
``complete`` so AirType can mark those clip requests saved.
"""

from __future__ import annotations

from datetime import datetime, timezone
import json
import secrets
import threading
from pathlib import Path
from typing import Any, Optional
from urllib.parse import quote, urlencode

from . import clip_requests

_lock = threading.RLock()
_directory: Optional[Path] = None


def configure(data_dir: str) -> None:
    global _directory
    root = Path(data_dir).expanduser()
    directory = root / "obsidian-exports"
    directory.mkdir(parents=True, exist_ok=True)
    with _lock:
        _directory = directory


def create(
    *,
    base_url: str,
    vault_folder: str = "",
    ids: Optional[list[str]] = None,
) -> dict[str, Any]:
    """Build a manifest for the given clip ids (or every ready pending note)."""
    notes, note_ids = _collect_notes(ids)
    if not notes:
        raise ValueError("No completed notes ready to export")

    export_id = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(4)
    token = secrets.token_urlsafe(24)
    base = base_url.rstrip("/")
    download_url = f"{base}/api/obsidian-exports/{quote(export_id, safe='')}?{urlencode({'token': token})}"
    complete_url = f"{base}/api/obsidian-exports/{quote(export_id, safe='')}/complete?{urlencode({'token': token})}"
    open_url = f"airtype://obsidian-import?url={quote(download_url, safe='')}"

    manifest = {
        "schema_version": 1,
        "kind": "airtype.obsidian_import",
        "exported_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "source": {"app": "airtype-webui", "base_url": base},
        "vault_folder": vault_folder or None,
        "notes": notes,
        "complete": {"method": "POST", "url": complete_url},
    }
    meta = {
        "id": export_id,
        "token": token,
        "note_ids": note_ids,
        "created_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "completed_at": None,
        "saved_ids": [],
        "failed_ids": [],
    }
    with _lock:
        directory = _directory_path()
        (directory / f"{export_id}.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        (directory / f"{export_id}.meta.json").write_text(
            json.dumps(meta, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    return {
        "export_id": export_id,
        "download_url": download_url,
        "open_url": open_url,
        "note_count": len(notes),
        "note_ids": note_ids,
    }


def get_manifest(export_id: str, token: str) -> dict[str, Any]:
    meta = _load_meta(export_id)
    if not meta or not _token_ok(meta, token):
        raise KeyError("export not found")
    path = _directory_path() / f"{export_id}.json"
    if not path.is_file():
        raise KeyError("export not found")
    loaded = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(loaded, dict):
        raise KeyError("export not found")
    return loaded


def complete(export_id: str, token: str, *, saved_ids: list[str], failed_ids: list[str] | None = None) -> dict[str, Any]:
    """Mark successfully written notes as saved in AirType."""
    with _lock:
        meta = _load_meta(export_id)
        if not meta or not _token_ok(meta, token):
            raise KeyError("export not found")
        allowed = set(str(item) for item in (meta.get("note_ids") or []))
        saved: list[str] = []
        for raw in saved_ids:
            request_id = str(raw or "").strip()
            if not request_id or request_id not in allowed:
                continue
            if clip_requests.mark_saved(request_id):
                saved.append(request_id)
        failed = [str(item) for item in (failed_ids or []) if str(item or "").strip() in allowed]
        meta["saved_ids"] = saved
        meta["failed_ids"] = failed
        meta["completed_at"] = datetime.now().astimezone().isoformat(timespec="seconds")
        _write_meta(export_id, meta)
        return {
            "export_id": export_id,
            "saved": len(saved),
            "failed": len(failed),
            "saved_ids": saved,
            "failed_ids": failed,
        }


def _collect_notes(ids: Optional[list[str]]) -> tuple[list[dict[str, Any]], list[str]]:
    wanted: Optional[set[str]] = None
    if ids is not None:
        wanted = {str(item).strip() for item in ids if str(item or "").strip()}
        if not wanted:
            return [], []

    notes: list[dict[str, Any]] = []
    note_ids: list[str] = []
    if wanted is None:
        candidates = [str(item.get("id") or "") for item in clip_requests.list_pending()]
    else:
        candidates = sorted(wanted)

    for request_id in candidates:
        if not request_id:
            continue
        if wanted is not None and request_id not in wanted:
            continue
        record = clip_requests.get(request_id) or {}
        if record.get("status") != "completed":
            continue
        if record.get("obsidian_save") == "complete":
            continue
        note = str(record.get("note") or "")
        if not note.strip():
            continue
        title = str(record.get("note_title") or record.get("title") or "").strip() or "Untitled"
        notes.append(
            {
                "id": request_id,
                "title": title,
                "markdown": note,
                "created_at": record.get("created_at") or None,
                "tags": record.get("tags") if isinstance(record.get("tags"), list) else None,
                "folder": None,
                "source_url": record.get("source") or None,
            }
        )
        note_ids.append(request_id)
    return notes, note_ids


def _directory_path() -> Path:
    if _directory is None:
        raise RuntimeError("obsidian_exports.configure() was not called")
    return _directory


def _load_meta(export_id: str) -> Optional[dict[str, Any]]:
    path = _directory_path() / f"{_safe_id(export_id)}.meta.json"
    if not path.is_file():
        return None
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return loaded if isinstance(loaded, dict) else None


def _write_meta(export_id: str, meta: dict[str, Any]) -> None:
    path = _directory_path() / f"{_safe_id(export_id)}.meta.json"
    path.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _token_ok(meta: dict[str, Any], token: str) -> bool:
    expected = str(meta.get("token") or "")
    supplied = str(token or "")
    return bool(expected) and bool(supplied) and secrets.compare_digest(expected, supplied)


def _safe_id(export_id: str) -> str:
    cleaned = "".join(ch for ch in str(export_id or "") if ch.isalnum() or ch in "-_")
    if not cleaned:
        raise KeyError("export not found")
    return cleaned
