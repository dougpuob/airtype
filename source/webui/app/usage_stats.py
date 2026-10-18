"""Usage statistics for the WebUI dashboard.

Two jobs live here:

* ``log_llm_usage`` appends one JSON line per LLM call to
  ``<data_dir>/llm-usage.jsonl``. It must never raise.
* ``compute_stats`` reads capture records, clip requests, IME dictations and
  the LLM usage log and returns the numbers the dashboard shows.
"""

from __future__ import annotations

import glob
import json
import os
import re
import threading
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable, Optional
from urllib.parse import urlparse

LLM_USAGE_FILENAME = "llm-usage.jsonl"
_log_lock = threading.Lock()


# --------------------------------------------------------------------------- #
# LLM usage log
# --------------------------------------------------------------------------- #

def llm_usage_path(data_dir: str) -> str:
    return os.path.join(data_dir, LLM_USAGE_FILENAME)


def usage_from_payload(payload: Any) -> dict[str, Optional[int]]:
    """Token counts from an OpenAI-compatible or Ollama response."""
    tokens: dict[str, Optional[int]] = {"prompt_tokens": None, "completion_tokens": None, "total_tokens": None}
    if not isinstance(payload, dict):
        return tokens
    usage = payload.get("usage")
    if isinstance(usage, dict):
        for key in tokens:
            tokens[key] = _int_or_none(usage.get(key))
    else:  # Ollama /api/chat
        tokens["prompt_tokens"] = _int_or_none(payload.get("prompt_eval_count"))
        tokens["completion_tokens"] = _int_or_none(payload.get("eval_count"))
    if tokens["total_tokens"] is None and tokens["prompt_tokens"] is not None and tokens["completion_tokens"] is not None:
        tokens["total_tokens"] = tokens["prompt_tokens"] + tokens["completion_tokens"]
    return tokens


def log_llm_usage(data_dir: str, entry: dict[str, Any]) -> None:
    """Append one usage entry. Swallows every error so LLM calls never break."""
    try:
        line = json.dumps(entry, ensure_ascii=False)
        os.makedirs(data_dir, exist_ok=True)
        with _log_lock:
            with open(llm_usage_path(data_dir), "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
    except Exception:
        pass


def read_llm_usage(data_dir: str) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    try:
        with open(llm_usage_path(data_dir), encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    item = json.loads(line)
                except ValueError:
                    continue
                if isinstance(item, dict):
                    entries.append(item)
    except OSError:
        pass
    return entries


# --------------------------------------------------------------------------- #
# Normalisation helpers
# --------------------------------------------------------------------------- #

def site_for_url(url: str, *, kind: str = "") -> str:
    """Group a capture URL into a site name."""
    if not url:
        return "Upload" if kind in {"upload", ""} else "Unknown"
    host = (urlparse(url).hostname or "").lower()
    if not host:
        return "Upload"
    if host.startswith("www."):
        host = host[4:]
    if host.startswith("m."):
        host = host[2:]
    if host in {"youtu.be"} or host.endswith("youtube.com"):
        return "YouTube"
    if host == "b23.tv" or host.endswith("bilibili.com"):
        return "Bilibili"
    if host.endswith("instagram.com") or host.endswith("cdninstagram.com"):
        return "Instagram"
    if host.endswith("threads.com") or host.endswith("threads.net"):
        return "Threads"
    if host in {"x.com", "twitter.com"} or host.endswith(".x.com"):
        return "X"
    if host.endswith("facebook.com") or host == "fb.watch":
        return "Facebook"
    return host


_FAILURE_RULES: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"Stopped by user|已停止|cancel", re.I), "使用者停止"),
    (re.compile(r"(?s)(?=.*HTTP Error 403)(?=.*(JavaScript|deno))", re.I), "YouTube 403：無法解 JS challenge (deno)"),
    (re.compile(r"HTTP Error 403|403: Forbidden", re.I), "下載被拒 (HTTP 403)"),
    (re.compile(r"JavaScript runtime|challenge solver|\bdeno\b", re.I), "YouTube 缺少 JS runtime (deno)"),
    (re.compile(r"No video formats found", re.I), "找不到影片格式 (No video formats found)"),
    (re.compile(r"There is no video in this post", re.I), "貼文沒有影片"),
    (re.compile(r"did not contain a public MP4", re.I), "Threads 沒有公開 MP4"),
    (re.compile(r"empty media response|not granting access|login", re.I), "Instagram 拒絕存取 / 需登入"),
    (re.compile(r"timed? ?out", re.I), "逾時"),
    (re.compile(r"Local LLM|LLM", re.I), "LLM 失敗"),
]


def failure_reason(error: str) -> str:
    text = str(error or "").strip()
    if not text:
        return "未知原因"
    for pattern, label in _FAILURE_RULES:
        if pattern.search(text):
            return label
    text = re.sub(r"^Could not download media URL with yt-dlp:\s*", "", text)
    lines = [line for line in text.splitlines() if line.strip() and not line.startswith("WARNING:")]
    first = (lines[0] if lines else text).strip()
    first = re.sub(r"https?://\S+", "<url>", first)
    return first[:80]


def _int_or_none(value: Any) -> Optional[int]:
    try:
        if value is None or isinstance(value, bool):
            return None
        return int(value)
    except (TypeError, ValueError):
        return None


def _parse_time(value: Any) -> Optional[datetime]:
    if not value:
        return None
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value, tz=timezone.utc).astimezone()
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.astimezone()
    return parsed.astimezone()


def _id_time(job_id: str) -> Optional[datetime]:
    try:
        return datetime.strptime(job_id[:15], "%Y%m%d-%H%M%S").astimezone()
    except (TypeError, ValueError):
        return None


def _read_json(path: str) -> Optional[dict[str, Any]]:
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def _float(value: Any) -> float:
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def _week_start(moment: datetime) -> str:
    return (moment.date() - timedelta(days=moment.weekday())).isoformat()


# --------------------------------------------------------------------------- #
# Loading
# --------------------------------------------------------------------------- #

def load_captures(records_dir: str, requests_dir: str) -> list[dict[str, Any]]:
    """Every capture as a flat dict: transcript records plus clip requests
    (articles/posts) that did not create a transcript record."""
    captures: list[dict[str, Any]] = []
    seen_jobs: set[str] = set()
    for path in glob.glob(os.path.join(records_dir, "transcript", "*", "record.json")):
        record = _read_json(path)
        if not record:
            continue
        job_id = str(record.get("job_id") or os.path.basename(os.path.dirname(path)))
        seen_jobs.add(job_id)
        request = record.get("request") if isinstance(record.get("request"), dict) else {}
        source = record.get("source") if isinstance(record.get("source"), dict) else {}
        url = str(request.get("url") or source.get("url") or "")
        kind = str(request.get("kind") or "")
        article = record.get("article") if isinstance(record.get("article"), dict) else {}
        transcript = record.get("transcript") if isinstance(record.get("transcript"), dict) else {}
        details = record.get("details") if isinstance(record.get("details"), dict) else {}
        article_chars = 0
        if str(article.get("text") or "").strip():
            article_chars = int(
                _float(article.get("request_chars"))
                or _float(details.get("article_request_chars"))
                or len(str(transcript.get("text") or ""))
            )
        captures.append(
            {
                "id": job_id,
                "kind": "video" if kind == "url" else (kind or "video"),
                "site": site_for_url(url, kind=kind),
                "url": url,
                "title": str(record.get("title") or source.get("name") or ""),
                "status": str(record.get("status") or "unknown"),
                "error": str(record.get("error") or ""),
                "created_at": _parse_time(record.get("created_at")) or _id_time(job_id),
                "duration": _float(details.get("duration") or transcript.get("duration")),
                "llm_input_chars_estimate": article_chars,
            }
        )

    for path in glob.glob(os.path.join(requests_dir, "*.json")):
        request = _read_json(path)
        if not request:
            continue
        job_id = str(request.get("job_id") or "")
        if job_id and job_id in seen_jobs:
            continue
        url = str(request.get("source") or "")
        status = str(request.get("status") or "unknown")
        error = str(request.get("error") or "")
        if status == "failed" and error in {"已停止", "Stopped by user"}:
            status = "cancelled"
        estimate = 0
        if str(request.get("polished_content") or "").strip():
            estimate = len(str(request.get("content") or ""))
        captures.append(
            {
                "id": str(request.get("id") or os.path.splitext(os.path.basename(path))[0]),
                "kind": str(request.get("kind") or "clip"),
                "site": site_for_url(url, kind="url"),
                "url": url,
                "title": str(request.get("title") or ""),
                "status": status,
                "error": error,
                "created_at": _parse_time(request.get("created_at")) or _id_time(str(request.get("id") or "")),
                "duration": 0.0,
                "llm_input_chars_estimate": estimate,
            }
        )
    return captures


def load_ime(records_dir: str) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    for path in glob.glob(os.path.join(records_dir, "ime", "*", "record.json")):
        record = _read_json(path)
        if not record:
            continue
        result = record.get("result") if isinstance(record.get("result"), dict) else {}
        transcript = record.get("transcript") if isinstance(record.get("transcript"), dict) else {}
        job_id = str(record.get("job_id") or os.path.basename(os.path.dirname(path)))
        items.append(
            {
                "created_at": _parse_time(record.get("created_at")) or _id_time(job_id),
                "duration": _float(result.get("duration") or transcript.get("duration")),
                "chars": len(str(transcript.get("text") or "")),
                "status": str(record.get("status") or ""),
            }
        )
    return items


# --------------------------------------------------------------------------- #
# Aggregation
# --------------------------------------------------------------------------- #

def _status_bucket(status: str) -> str:
    if status in {"completed", "failed", "cancelled"}:
        return status
    return "other"


def _days(now: datetime, days: int) -> list[str]:
    start = now.date() - timedelta(days=days - 1)
    return [(start + timedelta(days=offset)).isoformat() for offset in range(days)]


def aggregate_captures(captures: list[dict[str, Any]], now: datetime, days: int = 30) -> dict[str, Any]:
    by_site: dict[str, Counter] = defaultdict(Counter)
    failures: Counter = Counter()
    failure_sites: dict[str, Counter] = defaultdict(Counter)
    per_day: Counter = Counter()
    per_week: Counter = Counter()
    totals: Counter = Counter()
    for capture in captures:
        bucket = _status_bucket(capture["status"])
        totals[bucket] += 1
        by_site[capture["site"]][bucket] += 1
        if bucket in {"failed", "cancelled"}:
            reason = failure_reason(capture["error"] or ("Stopped by user" if bucket == "cancelled" else ""))
            failures[reason] += 1
            failure_sites[reason][capture["site"]] += 1
        moment = capture.get("created_at")
        if isinstance(moment, datetime):
            per_day[moment.date().isoformat()] += 1
            per_week[_week_start(moment)] += 1

    total = sum(totals.values())
    finished = totals["completed"] + totals["failed"]
    sites = []
    for site, counts in by_site.items():
        site_total = sum(counts.values())
        sites.append(
            {
                "site": site,
                "total": site_total,
                "completed": counts["completed"],
                "failed": counts["failed"],
                "cancelled": counts["cancelled"],
                "other": counts["other"],
                "success_rate": round(counts["completed"] / (counts["completed"] + counts["failed"]), 3)
                if counts["completed"] + counts["failed"]
                else None,
            }
        )
    sites.sort(key=lambda item: (-item["total"], item["site"]))

    recent = sorted(
        (c for c in captures if isinstance(c.get("created_at"), datetime)),
        key=lambda c: c["created_at"],
        reverse=True,
    )[:10]
    first = min((c["created_at"] for c in captures if isinstance(c.get("created_at"), datetime)), default=None)
    return {
        "total": total,
        "completed": totals["completed"],
        "failed": totals["failed"],
        "cancelled": totals["cancelled"],
        "other": totals["other"],
        "success_rate": round(totals["completed"] / finished, 3) if finished else None,
        "first_capture_at": first.isoformat() if first else None,
        "by_site": sites,
        "failure_reasons": [
            {"reason": reason, "count": count, "sites": dict(failure_sites[reason])}
            for reason, count in failures.most_common(10)
        ],
        "by_day": [{"date": day, "count": per_day.get(day, 0)} for day in _days(now, days)],
        "by_week": [{"week": week, "count": per_week[week]} for week in sorted(per_week)],
        "recent": [
            {
                "id": c["id"],
                "kind": c["kind"],
                "site": c["site"],
                "title": c["title"][:120],
                "url": c["url"],
                "status": c["status"],
                "error": failure_reason(c["error"]) if c["status"] in {"failed", "cancelled"} else "",
                "created_at": c["created_at"].isoformat(),
            }
            for c in recent
        ],
    }


def aggregate_ime(items: list[dict[str, Any]], now: datetime, days: int = 30) -> dict[str, Any]:
    per_day: Counter = Counter()
    for item in items:
        moment = item.get("created_at")
        if isinstance(moment, datetime):
            per_day[moment.date().isoformat()] += 1
    return {
        "count": len(items),
        "total_duration_seconds": round(sum(item["duration"] for item in items), 1),
        "total_chars": sum(item["chars"] for item in items),
        "by_day": [{"date": day, "count": per_day.get(day, 0)} for day in _days(now, days)],
    }


def _token_bucket() -> dict[str, int]:
    return {"calls": 0, "prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0, "input_chars": 0, "output_chars": 0}


def _add_usage(bucket: dict[str, int], entry: dict[str, Any]) -> None:
    bucket["calls"] += 1
    for key in ("prompt_tokens", "completion_tokens", "total_tokens", "input_chars", "output_chars"):
        bucket[key] += _int_or_none(entry.get(key)) or 0


def aggregate_llm(entries: list[dict[str, Any]], captures: list[dict[str, Any]], now: datetime, days: int = 30) -> dict[str, Any]:
    totals = _token_bucket()
    by_step: dict[str, dict[str, int]] = defaultdict(_token_bucket)
    by_model: dict[str, dict[str, int]] = defaultdict(_token_bucket)
    by_day: dict[str, dict[str, int]] = defaultdict(_token_bucket)
    failed = 0
    missing_usage = 0
    duration_ms = 0
    first: Optional[datetime] = None
    for entry in entries:
        _add_usage(totals, entry)
        _add_usage(by_step[str(entry.get("step") or "chat")], entry)
        _add_usage(by_model[str(entry.get("model") or "unknown")], entry)
        moment = _parse_time(entry.get("timestamp"))
        if moment:
            _add_usage(by_day[moment.date().isoformat()], entry)
            first = moment if first is None or moment < first else first
        if not entry.get("success", True):
            failed += 1
        if entry.get("prompt_tokens") is None:
            missing_usage += 1
        duration_ms += _int_or_none(entry.get("duration_ms")) or 0

    estimated = [c for c in captures if c.get("llm_input_chars_estimate")]
    return {
        "logged_since": first.isoformat() if first else None,
        "totals": {**totals, "failed_calls": failed, "calls_without_usage": missing_usage, "duration_ms": duration_ms},
        "by_step": [{"step": key, **value} for key, value in sorted(by_step.items(), key=lambda kv: -kv[1]["total_tokens"])],
        "by_model": [{"model": key, **value} for key, value in sorted(by_model.items(), key=lambda kv: -kv[1]["total_tokens"])],
        "by_day": [{"date": day, **by_day.get(day, _token_bucket())} for day in _days(now, days)],
        "historical_estimate": {
            "is_estimate": True,
            "note": "No token usage was recorded before llm-usage.jsonl existed; this is the character count of text sent for polishing (prompt request_chars, else transcript length). Title/tag calls are not included.",
            "captures": len(estimated),
            "input_chars": sum(int(c["llm_input_chars_estimate"]) for c in estimated),
        },
    }


def compute_stats(data_dir: str, *, now: Optional[datetime] = None, days: int = 30) -> dict[str, Any]:
    now = (now or datetime.now(timezone.utc)).astimezone()
    records_dir = os.path.join(data_dir, "records")
    captures = load_captures(records_dir, os.path.join(data_dir, "requests"))
    return {
        "generated_at": now.isoformat(),
        "days": days,
        "captures": aggregate_captures(captures, now, days),
        "ime": aggregate_ime(load_ime(records_dir), now, days),
        "llm": aggregate_llm(read_llm_usage(data_dir), captures, now, days),
    }
