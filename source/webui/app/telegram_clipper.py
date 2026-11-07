"""Private-chat Telegram intake for the Obsidian Clipper.

The WebUI process polls Bot API ``getUpdates`` itself. There is no webhook
and no new HTTP route. Each accepted URL is handed to the same
``_submit_clip_url`` path the clipper UI uses.

The worker stays idle unless ``[webui.telegram] enabled`` is true. It never
trusts the first sender: both ``allowed_user_id`` and ``allowed_chat_id``
must be set to positive ids before a URL is queued. ``/start``, ``/whoami``,
and ``/id`` in a private chat only record a pairing candidate.

Offset advances only after the update is durable locally. A repeated
Telegram update uses an idempotency key so a crash between enqueue and the
offset write does not download twice. The clipper itself does not dedupe
distinct messages that happen to carry the same URL.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import ipaddress
import json
import os
import re
import socket
import threading
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, Optional

from .config_schema import read_config
from . import web_article


API_ROOT = "https://api.telegram.org"
MAX_URLS_PER_MESSAGE = 5
MAX_URL_LENGTH = 2048
MAX_PAIRING_CANDIDATES = 20
PAIRING_COMMANDS = {"/start", "/whoami", "/id"}
DEFAULT_POLL_TIMEOUT = 25

# Same IPv4 ranges as web_article.BLOCKED_HOST_PATTERN. Tailscale's CGNAT
# range (100.64.0.0/10) and IPv6 ULA are intentionally absent: the clipper
# already reaches Tailscale services by address and by MagicDNS name.
_BLOCKED_V4 = (
    ipaddress.ip_network("0.0.0.0/8"),
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)
_LINK_LOCAL_V6 = ipaddress.ip_network("fe80::/10")
# Alibaba Cloud metadata. Not 100.100.100.100, which is Tailscale MagicDNS.
_METADATA_V4 = {ipaddress.ip_address("100.100.169.254")}
_METADATA_HOSTS = {"metadata.google.internal", "metadata.goog"}
_NUMERIC_HOST = re.compile(r"^(?:0x[0-9a-fA-F]+|\d+)(?:\.(?:0x[0-9a-fA-F]+|\d+)){0,3}$")
_BOT_TOKEN_RE = re.compile(r"\d{6,}:[A-Za-z0-9_-]{20,}")
_TELEGRAM_URL_RE = re.compile(r"https://api\.telegram\.org/bot\S+")
_URL_RE = re.compile(r"https?://[^\s\"'<>]+")

Log = Callable[[str], None]
Submit = Callable[..., dict[str, Any]]
Recover = Callable[[], None]
TransportFactory = Callable[[str], "TelegramTransport"]


class TelegramApiError(Exception):
    def __init__(self, status: int, description: str, retry_after: Optional[float] = None) -> None:
        super().__init__(description)
        self.status = int(status or 0)
        self.description = description
        self.retry_after = retry_after


class TelegramTransport:
    def call(self, method: str, params: Mapping[str, Any], timeout: float) -> dict[str, Any]:
        raise NotImplementedError


@dataclass(frozen=True)
class Settings:
    enabled: bool = False
    token: str = ""
    token_file: str = ""
    token_error: str = ""
    allowed_user_id: Optional[int] = None
    allowed_chat_id: Optional[int] = None
    replies_enabled: bool = False

    @property
    def allowlist_ready(self) -> bool:
        return _positive_id(self.allowed_user_id) is not None and _positive_id(self.allowed_chat_id) is not None

    def __repr__(self) -> str:
        return (
            "Settings("
            f"enabled={self.enabled}, token={'set' if self.token else 'unset'}, "
            f"allowlist_ready={self.allowlist_ready}, replies_enabled={self.replies_enabled})"
        )


def load_settings(config_path: str | Path, env: Optional[Mapping[str, str]] = None) -> Settings:
    """Settings from ``[webui.telegram]``, overridden by process environment.

    The bot token is read from ``AIRTYPE_TELEGRAM_BOT_TOKEN`` or from the
    file named by ``token_file`` / ``AIRTYPE_TELEGRAM_TOKEN_FILE``. It is
    never taken from a value committed in the repository.
    """
    source = os.environ if env is None else env
    loaded = read_config(config_path)
    webui = loaded.get("webui") if isinstance(loaded, dict) else None
    section = webui.get("telegram") if isinstance(webui, dict) else None
    if not isinstance(section, dict):
        section = {}
    enabled = _env_bool(source, "AIRTYPE_TELEGRAM_ENABLED", _as_bool(section.get("enabled"), False))
    replies = _env_bool(source, "AIRTYPE_TELEGRAM_REPLIES", _as_bool(section.get("replies_enabled"), False))
    token_file = str(source.get("AIRTYPE_TELEGRAM_TOKEN_FILE") or section.get("token_file") or "").strip()
    token = str(source.get("AIRTYPE_TELEGRAM_BOT_TOKEN") or "").strip()
    token_error = ""
    if not token and token_file:
        token, token_error = _read_token_file(token_file)
    return Settings(
        enabled=enabled,
        token=token,
        token_file=token_file,
        token_error=token_error,
        allowed_user_id=_env_id(source, "AIRTYPE_TELEGRAM_ALLOWED_USER_ID", section.get("allowed_user_id")),
        allowed_chat_id=_env_id(source, "AIRTYPE_TELEGRAM_ALLOWED_CHAT_ID", section.get("allowed_chat_id")),
        replies_enabled=replies,
    )


def token_file_warning(path: str) -> str:
    if not path or not os.path.isfile(path):
        return ""
    try:
        mode = os.stat(path).st_mode
    except OSError:
        return ""
    if mode & 0o077:
        return "telegram token file is readable by group or others; chmod 600"
    return ""


def blocked_target_reason(url: str) -> str:
    """Why this URL must not be enqueued, or ``""`` when the clipper may take it.

    Uses ``web_article.blocked_host_reason`` (localhost, ``.local``, and the
    loopback / private / link-local hostname patterns the web-article
    pipeline already refuses) plus obfuscated literals of those same ranges.
    Hostnames the clipper already accepts, including ``*.ts.net`` and
    Tailscale CGNAT addresses, stay accepted. DNS is not resolved and this
    function does not fetch the URL: redirect following stays inside the
    clipper downloaders, which is where a pasted clip URL is fetched today.
    """
    if len(url or "") > MAX_URL_LENGTH:
        return "too_long"
    try:
        parsed = urllib.parse.urlsplit(url)
    except ValueError:
        return "bad_url"
    if parsed.scheme.lower() not in {"http", "https"}:
        return "bad_scheme"
    if parsed.username is not None or parsed.password is not None:
        return "url_credentials"
    host = (parsed.hostname or "").lower().rstrip(".")
    if not host:
        return "bad_host"
    if host in _METADATA_HOSTS or host.endswith(".metadata.google.internal"):
        return "metadata_host"
    if web_article.blocked_host_reason(url):
        return "blocked_host"
    literal = _literal_ip(host)
    if literal is not None and _is_blocked_ip(literal):
        return "blocked_host"
    return ""


def redact(text: str, token: str = "") -> str:
    """Remove bot tokens, Telegram API URLs, and URL userinfo or query strings."""
    cleaned = str(text or "")
    if token:
        cleaned = cleaned.replace(token, "[redacted]")
    cleaned = _BOT_TOKEN_RE.sub("[redacted]", cleaned)
    cleaned = _TELEGRAM_URL_RE.sub("https://api.telegram.org/bot[redacted]/", cleaned)

    def _strip(match: re.Match[str]) -> str:
        raw = match.group(0)
        try:
            parts = urllib.parse.urlsplit(raw)
        except ValueError:
            return "[redacted-url]"
        if parts.username or parts.password or parts.query:
            host = parts.hostname or ""
            return urllib.parse.urlunsplit((parts.scheme, host, parts.path, "", ""))
        return raw

    return _URL_RE.sub(_strip, cleaned)


def recover_interrupted(records: list[dict[str, Any]], submit: Submit, log: Log) -> int:
    """Redrive telegram clips that a restart marked interrupted. Same request id."""
    restarted = 0
    for record in records:
        key = str(record.get("idempotency_key") or "")
        request_id = str(record.get("id") or "")
        if not key.startswith("telegram:"):
            continue
        source = str(record.get("source") or "")
        reason = blocked_target_reason(source)
        if reason:
            log(f"telegram recovery skipped id={request_id} reason={reason}")
            continue
        submit(source, origin="telegram", idempotency_key=key, notes=str(record.get("notes") or ""))
        restarted += 1
        log(f"telegram recovery requeued id={request_id}")
    return restarted


class DurableState:
    """``next_offset`` plus the clip id already stored for each idempotency key."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.next_offset = 0
        self.items: dict[str, dict[str, Any]] = {}
        self.load()

    def load(self) -> None:
        if not self.path.is_file():
            return
        try:
            loaded = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        if not isinstance(loaded, dict):
            return
        try:
            self.next_offset = max(0, int(loaded.get("next_offset") or 0))
        except (TypeError, ValueError):
            self.next_offset = 0
        raw_items = loaded.get("items")
        if isinstance(raw_items, dict):
            self.items = {str(key): value for key, value in raw_items.items() if isinstance(value, dict)}

    def clip_id(self, key: str) -> str:
        item = self.items.get(key) or {}
        return str(item.get("clip_request_id") or "")

    def remember(self, key: str, clip_request_id: str) -> None:
        self.items[key] = {"clip_request_id": clip_request_id}
        self.save()

    def commit_offset(self, offset: int) -> None:
        self.next_offset = max(self.next_offset, int(offset))
        stale = [key for key in self.items if _key_update_id(key) < self.next_offset]
        for key in stale:
            self.items.pop(key, None)
        self.save()

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(self.path.parent, 0o700)
        payload = json.dumps(
            {"next_offset": self.next_offset, "items": self.items},
            ensure_ascii=False,
            indent=2,
        )
        temporary = self.path.with_suffix(".json.tmp")
        with temporary.open("w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, self.path)
        os.chmod(self.path, 0o600)


class Poller:
    def __init__(
        self,
        *,
        settings_loader: Callable[[], Settings],
        state_path: Path,
        pairing_path: Path,
        submit: Submit,
        log: Log,
        transport_factory: Optional[TransportFactory] = None,
        recover: Optional[Recover] = None,
        poll_timeout: int = DEFAULT_POLL_TIMEOUT,
    ) -> None:
        self._load_settings = settings_loader
        self._state = DurableState(state_path)
        self._pairing_path = pairing_path
        self._submit = submit
        self._log = log
        self._transport_factory = transport_factory or (lambda token: UrllibTelegramTransport(token))
        self._recover = recover or (lambda: None)
        self._poll_timeout = max(0, int(poll_timeout))
        self._backoff = 1.0
        self._last_notice = ""
        self._recovered = False

    def serve(self, stop: threading.Event) -> None:
        while not stop.is_set():
            token = ""
            try:
                settings = self._load_settings()
                token = settings.token
                if not settings.enabled:
                    self._notice("disabled", "telegram clipper disabled")
                    stop.wait(5)
                    continue
                if settings.token_error:
                    self._notice("token_error", "telegram clipper " + settings.token_error)
                    stop.wait(5)
                    continue
                if not settings.token:
                    self._notice("no_token", "telegram clipper enabled but no bot token is configured")
                    stop.wait(5)
                    continue
                warning = token_file_warning(settings.token_file)
                if warning:
                    self._notice("token_mode", warning)
                if not self._recovered:
                    self._recover()
                    self._recovered = True
                self.run_once(settings)
                self._backoff = 1.0
            except TelegramApiError as error:
                wait = self.failure_wait(error)
                self._log("telegram api error: " + redact(error.description, token))
                stop.wait(wait)
            except Exception as error:
                wait = self.failure_wait(TelegramApiError(0, "error"))
                self._log("telegram poller error: " + redact(f"{type(error).__name__}: {error}", token))
                stop.wait(wait)

    def run_once(self, settings: Settings) -> int:
        """Poll once and process the returned batch. Returns how many updates were handled."""
        if not settings.enabled or not settings.token:
            return 0
        transport = self._transport_factory(settings.token)
        self._guard_webhook(transport)
        params: dict[str, Any] = {
            "timeout": self._poll_timeout,
            "limit": 20,
            "allowed_updates": ["message"],
        }
        if self._state.next_offset > 0:
            params["offset"] = self._state.next_offset
        payload = transport.call("getUpdates", params, timeout=self._poll_timeout + 10)
        updates = payload.get("result") if isinstance(payload, dict) else None
        if not isinstance(updates, list):
            raise TelegramApiError(0, "getUpdates returned no result list")
        handled = 0
        for update in sorted(updates, key=_update_sort_key):
            if not isinstance(update, dict):
                continue
            self._accept_update(settings, transport, update)
            handled += 1
        return handled

    def failure_wait(self, error: TelegramApiError) -> float:
        if error.status == 409:
            return 30.0
        if error.status == 401:
            return 60.0
        if error.retry_after:
            return max(1.0, min(float(error.retry_after), 300.0))
        wait = self._backoff
        self._backoff = min(self._backoff * 2, 60.0)
        return wait

    def _guard_webhook(self, transport: TelegramTransport) -> None:
        payload = transport.call("getWebhookInfo", {}, timeout=20)
        result = payload.get("result") if isinstance(payload, dict) else None
        url = str(result.get("url") or "") if isinstance(result, dict) else ""
        if url:
            raise TelegramApiError(
                409,
                "webhook is active; polling is paused until it is removed out of band. deleteWebhook is not called",
            )

    def _accept_update(self, settings: Settings, transport: TelegramTransport, update: Mapping[str, Any]) -> None:
        try:
            update_id = int(update["update_id"])
        except (KeyError, TypeError, ValueError):
            return
        if update_id < self._state.next_offset:
            return
        message = update.get("message")
        if not isinstance(message, dict):
            self._state.commit_offset(update_id + 1)
            return
        command = _pairing_command(message)
        if command and _is_private(message):
            self._record_pairing(message, update_id, command)
            self._state.commit_offset(update_id + 1)
            return
        authorized, reason = _authorization(settings, message)
        urls = extract_http_urls(message)
        if not authorized:
            if urls:
                self._log(
                    "telegram drop "
                    f"update_id={update_id} user_id={_id_for_log(_sender_id(message))} "
                    f"chat_id={_id_for_log(_chat_id(message))} reason={reason}"
                )
            self._state.commit_offset(update_id + 1)
            return
        queued: list[str] = []
        rejected: dict[str, int] = {}
        for ordinal, url in enumerate(urls):
            block = blocked_target_reason(url)
            if not block and len(queued) >= MAX_URLS_PER_MESSAGE:
                block = "limit"
            if block:
                rejected[block] = rejected.get(block, 0) + 1
                continue
            key = _idempotency_key(update_id, ordinal, url)
            existing = self._state.clip_id(key)
            if existing:
                queued.append(existing)
                continue
            record = self._submit(url, origin="telegram", idempotency_key=key)
            clip_id = str((record or {}).get("id") or "")
            if not clip_id:
                raise RuntimeError("clipper enqueue returned no request id")
            self._state.remember(key, clip_id)
            queued.append(clip_id)
        if queued:
            self._log(f"telegram queued update_id={update_id} count={len(queued)} clip_request_id={queued[0]}")
            if settings.replies_enabled:
                self._reply(settings, transport, len(queued))
        if rejected:
            summary = ",".join(f"{name}={count}" for name, count in sorted(rejected.items()))
            self._log(f"telegram rejected update_id={update_id} {summary}")
        self._state.commit_offset(update_id + 1)

    def _reply(self, settings: Settings, transport: TelegramTransport, count: int) -> None:
        noun = "clip" if count == 1 else "clips"
        try:
            transport.call(
                "sendMessage",
                {"chat_id": settings.allowed_chat_id, "text": f"Queued {count} {noun}."},
                timeout=20,
            )
        except TelegramApiError as error:
            self._log("telegram reply failed: " + redact(error.description, settings.token))

    def _record_pairing(self, message: Mapping[str, Any], update_id: int, command: str) -> None:
        user_id = _sender_id(message)
        chat_id = _chat_id(message)
        if user_id is None or chat_id is None:
            self._log(f"telegram pairing ignored update_id={update_id} reason=missing_sender")
            return
        sender = message.get("from") if isinstance(message.get("from"), dict) else {}
        entry = {
            "user_id": user_id,
            "chat_id": chat_id,
            "username": str(sender.get("username") or ""),
            "first_name": str(sender.get("first_name") or ""),
            "language_code": str(sender.get("language_code") or ""),
            "chat_type": "private",
            "update_id": update_id,
            "command": command,
            "received_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
        _write_pairing(self._pairing_path, entry)
        username = _log_token(entry["username"])
        self._log(
            "telegram pairing candidate "
            f"user_id={user_id} chat_id={chat_id} username={username} "
            f"update_id={update_id} command={command}"
        )

    def _notice(self, code: str, message: str) -> None:
        if self._last_notice == code:
            return
        self._last_notice = code
        self._log(message)


class UrllibTelegramTransport(TelegramTransport):
    """POST JSON to the official Bot API. The token stays in the URL path and out of errors."""

    def __init__(self, token: str) -> None:
        self._token = token

    def call(self, method: str, params: Mapping[str, Any], timeout: float) -> dict[str, Any]:
        if method not in {"getUpdates", "getWebhookInfo", "sendMessage"}:
            raise TelegramApiError(0, "refusing telegram method")
        url = f"{API_ROOT}/bot{self._token}/{method}"
        body = json.dumps(dict(params)).encode("utf-8")
        request = urllib.request.Request(
            url,
            data=body,
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            status = int(error.code or 0)
            if status == 409:
                raise TelegramApiError(
                    409,
                    "webhook is active; polling is paused until it is removed out of band. deleteWebhook is not called",
                ) from None
            raise TelegramApiError(status, _http_description(detail), retry_after=_retry_after(detail)) from None
        except urllib.error.URLError:
            raise TelegramApiError(0, "network error") from None
        except TimeoutError:
            raise TelegramApiError(0, "network error") from None
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise TelegramApiError(0, "telegram response was not json") from error
        if not isinstance(payload, dict) or not payload.get("ok"):
            description = str(payload.get("description") or "telegram request failed") if isinstance(payload, dict) else "telegram request failed"
            raise TelegramApiError(0, redact(description, self._token))
        return payload


def extract_http_urls(message: Mapping[str, Any]) -> list[str]:
    """http(s) ``url`` and ``text_link`` entities from the text and the caption, in order."""
    found: list[str] = []
    seen: set[str] = set()
    chunks = (
        (message.get("text"), message.get("entities")),
        (message.get("caption"), message.get("caption_entities")),
    )
    for text, entities in chunks:
        if not isinstance(text, str) or not isinstance(entities, list):
            continue
        for entity in entities:
            if not isinstance(entity, dict):
                continue
            url = _entity_url(text, entity)
            if not url or url in seen:
                continue
            seen.add(url)
            found.append(url)
    return found


def acquire_poll_lock(path: Path):
    """Exclusive non-blocking lock. ``None`` when another process already holds it."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = open(path, "a+")
    try:
        import fcntl

        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None
    return handle


def _entity_url(text: str, entity: Mapping[str, Any]) -> str:
    kind = str(entity.get("type") or "")
    if kind == "text_link":
        raw = str(entity.get("url") or "").strip()
    elif kind == "url":
        raw = _utf16_slice(text, entity.get("offset"), entity.get("length")).strip()
    else:
        return ""
    return _canonicalize(raw)


def _canonicalize(url: str) -> str:
    try:
        parsed = urllib.parse.urlsplit(url.strip())
    except ValueError:
        return ""
    scheme = parsed.scheme.lower()
    if scheme not in {"http", "https"} or not parsed.netloc:
        return ""
    return urllib.parse.urlunsplit((scheme, parsed.netloc, parsed.path, parsed.query, parsed.fragment))


def _utf16_slice(text: str, offset: Any, length: Any) -> str:
    try:
        start = int(offset)
        count = int(length)
    except (TypeError, ValueError):
        return ""
    if start < 0 or count <= 0:
        return ""
    encoded = text.encode("utf-16-le")
    raw = encoded[start * 2 : (start + count) * 2]
    if len(raw) != count * 2:
        return ""
    try:
        return raw.decode("utf-16-le")
    except UnicodeDecodeError:
        return ""


def _pairing_command(message: Mapping[str, Any]) -> str:
    text = message.get("text")
    if not isinstance(text, str):
        text = message.get("caption") if isinstance(message.get("caption"), str) else ""
    command = str(text or "").strip().split(" ", 1)[0].split("@", 1)[0].lower()
    return command if command in PAIRING_COMMANDS else ""


def _is_private(message: Mapping[str, Any]) -> bool:
    chat = message.get("chat")
    return isinstance(chat, dict) and str(chat.get("type") or "") == "private"


def _authorization(settings: Settings, message: Mapping[str, Any]) -> tuple[bool, str]:
    if not settings.allowlist_ready:
        return False, "allowlist_unset"
    if not _is_private(message):
        return False, "not_private"
    user_id = _sender_id(message)
    chat_id = _chat_id(message)
    if user_id is None or chat_id is None:
        return False, "missing_sender"
    if user_id != settings.allowed_user_id or chat_id != settings.allowed_chat_id:
        return False, "allowlist"
    return True, ""


def _sender_id(message: Mapping[str, Any]) -> Optional[int]:
    sender = message.get("from")
    if not isinstance(sender, dict):
        return None
    return _positive_id(sender.get("id"))


def _chat_id(message: Mapping[str, Any]) -> Optional[int]:
    chat = message.get("chat")
    if not isinstance(chat, dict):
        return None
    return _positive_id(chat.get("id"))


def _idempotency_key(update_id: int, ordinal: int, url: str) -> str:
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()[:16]
    return f"telegram:{update_id}:{ordinal}:{digest}"


def _key_update_id(key: str) -> int:
    parts = str(key).split(":")
    if len(parts) < 3 or parts[0] != "telegram":
        return -1
    try:
        return int(parts[1])
    except ValueError:
        return -1


def _update_sort_key(update: Mapping[str, Any]) -> int:
    try:
        return int(update.get("update_id") or 0)
    except (TypeError, ValueError):
        return 0


def _write_pairing(path: Path, entry: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    existing: list[dict[str, Any]] = []
    if path.is_file():
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            loaded = []
        if isinstance(loaded, list):
            existing = [item for item in loaded if isinstance(item, dict)]
    kept = [
        item
        for item in existing
        if item.get("user_id") != entry.get("user_id") or item.get("chat_id") != entry.get("chat_id")
    ]
    payload = json.dumps([dict(entry), *kept][:MAX_PAIRING_CANDIDATES], ensure_ascii=False, indent=2) + "\n"
    temporary = path.with_suffix(".json.tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    os.chmod(path, 0o600)


def _literal_ip(host: str):
    try:
        return ipaddress.ip_address(host)
    except ValueError:
        pass
    if not _NUMERIC_HOST.fullmatch(host):
        return None
    try:
        packed = socket.inet_aton(host)
    except OSError:
        return None
    return ipaddress.IPv4Address(packed)


def _is_blocked_ip(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    if isinstance(ip, ipaddress.IPv6Address):
        mapped = ip.ipv4_mapped
        if mapped is not None:
            return _is_blocked_ip(mapped)
        return bool(ip.is_loopback or ip in _LINK_LOCAL_V6)
    if ip in _METADATA_V4:
        return True
    return any(ip in network for network in _BLOCKED_V4)


def _positive_id(value: Any) -> Optional[int]:
    if isinstance(value, bool) or value is None:
        return None
    try:
        number = int(str(value).strip())
    except (TypeError, ValueError):
        return None
    if number <= 0:
        return None
    return number


def _as_bool(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    text = str(value).strip().lower()
    if text in {"1", "true", "yes", "on"}:
        return True
    if text in {"0", "false", "no", "off", ""}:
        return False
    return default


def _env_bool(env: Mapping[str, str], name: str, fallback: bool) -> bool:
    if name not in env or str(env.get(name) or "").strip() == "":
        return fallback
    return _as_bool(env.get(name), fallback)


def _env_id(env: Mapping[str, str], name: str, fallback: Any) -> Optional[int]:
    if name in env and str(env.get(name) or "").strip() != "":
        return _positive_id(env.get(name))
    return _positive_id(fallback)


def _read_token_file(path: str) -> tuple[str, str]:
    try:
        text = Path(path).expanduser().read_text(encoding="utf-8")
    except OSError:
        return "", "token file could not be read"
    for line in text.splitlines():
        token = line.strip()
        if token:
            return token, ""
    return "", "token file is empty"


def _http_description(body: str) -> str:
    try:
        loaded = json.loads(body)
    except json.JSONDecodeError:
        return "http error"
    if not isinstance(loaded, dict):
        return "http error"
    return redact(str(loaded.get("description") or "http error"))[:300]


def _retry_after(body: str) -> Optional[float]:
    try:
        loaded = json.loads(body)
    except json.JSONDecodeError:
        return None
    if not isinstance(loaded, dict):
        return None
    parameters = loaded.get("parameters")
    if not isinstance(parameters, dict) or "retry_after" not in parameters:
        return None
    try:
        return float(parameters["retry_after"])
    except (TypeError, ValueError):
        return None


def _id_for_log(value: Optional[int]) -> str:
    return str(value) if value is not None else "-"


def _log_token(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_@+-]", "", str(value or ""))[:64]
