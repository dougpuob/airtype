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
        "export_id": export_id,
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
        "revisions": _revisions_for(notes),
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
    """Confirm notes the Local App actually wrote.

    Only ids in this export are eligible. A note whose ``updated_at`` or exported
    fields (markdown, titles, tags) changed after the manifest was built stays pending. Notes that were not in
    the export are left alone. Calling complete again with the same ids is
    idempotent: an already-saved note stays saved and is reported again.
    Ids listed in ``failed_ids`` are not marked saved. The token is checked
    and then omitted from the response.
    """
    with _lock:
        meta = _load_meta(export_id)
        if not meta or not _token_ok(meta, token):
            raise KeyError("export not found")
        allowed_order = [str(item) for item in (meta.get("note_ids") or []) if str(item or "").strip()]
        allowed = set(allowed_order)
        revisions = meta.get("revisions") if isinstance(meta.get("revisions"), dict) else {}

        failed_seen: set[str] = set()
        failed: list[str] = []
        for raw in failed_ids or []:
            request_id = str(raw or "").strip()
            if not request_id or request_id not in allowed or request_id in failed_seen:
                continue
            failed_seen.add(request_id)
            failed.append(request_id)

        saved: list[str] = []
        rejected: list[dict[str, str]] = []
        seen: set[str] = set()
        eligible: list[str] = []
        for raw in saved_ids:
            request_id = str(raw or "").strip()
            if not request_id or request_id in seen:
                continue
            seen.add(request_id)
            if request_id not in allowed:
                rejected.append({"id": request_id, "reason": "not_in_export"})
                continue
            if request_id in failed_seen:
                continue
            eligible.append(request_id)
            reason = _confirm_exported_note(request_id, revisions.get(request_id))
            if reason == "saved":
                saved.append(request_id)
            else:
                rejected.append({"id": request_id, "reason": reason})

        saved_set = set(saved)
        previous = [str(item) for item in (meta.get("saved_ids") or []) if str(item or "") in allowed]
        for request_id in previous:
            saved_set.add(request_id)
        failed = [request_id for request_id in failed if request_id not in saved_set]
        meta["saved_ids"] = [request_id for request_id in allowed_order if request_id in saved_set]
        meta["failed_ids"] = failed
        meta["completed_at"] = datetime.now().astimezone().isoformat(timespec="seconds")
        _write_meta(export_id, meta)
        saved_set_response = set(saved)
        ok = all(request_id in saved_set_response for request_id in eligible)
        return {
            "ok": ok,
            "export_id": export_id,
            "saved": len(saved),
            "failed": len(failed),
            "saved_ids": saved,
            "failed_ids": failed,
            "rejected": rejected,
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
                "revision": {
                    "updated_at": str(record.get("updated_at") or ""),
                    "content_sha256": clip_requests.export_fingerprint(record),
                },
            }
        )
        note_ids.append(request_id)
    return notes, note_ids


def _revisions_for(notes: list[dict[str, Any]]) -> dict[str, dict[str, str]]:
    revisions: dict[str, dict[str, str]] = {}
    for note in notes:
        request_id = str(note.get("id") or "")
        revision = note.get("revision") if isinstance(note.get("revision"), dict) else {}
        if not request_id:
            continue
        revisions[request_id] = {
            "updated_at": str(revision.get("updated_at") or ""),
            "content_sha256": str(revision.get("content_sha256") or ""),
        }
    return revisions


def _confirm_exported_note(request_id: str, revision: Any) -> str:
    updated_at: Optional[str] = None
    content_sha256: Optional[str] = None
    if isinstance(revision, dict):
        updated_at = str(revision.get("updated_at") or "")
        content_sha256 = str(revision.get("content_sha256") or "")
    return clip_requests.mark_exported_note(
        request_id,
        updated_at=updated_at,
        content_sha256=content_sha256,
    )


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
