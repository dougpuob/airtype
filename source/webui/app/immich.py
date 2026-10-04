"""Minimal Immich REST API client for the Web Article image pipeline.

AirType uploads article images into a dedicated Immich account, tags them
with the note GUID, and creates one passwordless shared link per note so
Obsidian notes can render the images remotely. Endpoint shapes follow the
Immich server controllers (asset-media, tags, albums, shared-links).
"""

from __future__ import annotations

import hashlib
import http.client
import json
import os
import socket
import ssl
import struct
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any, Optional

# Tailscale's on-device MagicDNS resolver. It answers *.ts.net even when
# "Use Tailscale DNS" is off and the system resolver cannot see those names.
TAILSCALE_MAGICDNS = "100.100.100.100"


class ImmichError(RuntimeError):
    """Raised when Immich is not configured or rejects a request."""


IMAGE_EXTENSION_BY_CONTENT_TYPE = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/gif": ".gif",
    "image/webp": ".webp",
    "image/avif": ".avif",
    "image/bmp": ".bmp",
    "image/svg+xml": ".svg",
}


def _curl_requests():
    from curl_cffi import requests as curl_requests

    return curl_requests


def _is_literal_ip(host: str) -> bool:
    """True when ``host`` is already an IPv4 or IPv6 address."""
    candidate = host.strip().strip("[]")
    if not candidate:
        return False
    try:
        socket.inet_pton(socket.AF_INET, candidate)
        return True
    except OSError:
        pass
    try:
        socket.inet_pton(socket.AF_INET6, candidate)
        return True
    except OSError:
        return False


def _skip_dns_name(buf: bytes, offset: int) -> int:
    """Advance past a DNS name (labels or a compression pointer)."""
    while offset < len(buf):
        length = buf[offset]
        if length == 0:
            return offset + 1
        if length & 0xC0 == 0xC0:
            return offset + 2
        if length & 0xC0:
            raise ValueError("invalid DNS label")
        offset += 1 + length
    raise ValueError("truncated DNS name")


def dns_query_a(name: str, server: str = TAILSCALE_MAGICDNS, timeout: float = 1.5) -> str:
    """Return the first A record for ``name`` from ``server``, or ``""``.

    Used to resolve Tailscale MagicDNS names when the OS resolver does not
    have Tailscale DNS enabled. IPv4 is enough: Tailscale 100.x addresses
    are what AirType needs to reach Immich on the tailnet.
    """
    host = str(name or "").strip().rstrip(".")
    if not host or _is_literal_ip(host):
        return ""
    try:
        host = host.encode("idna").decode("ascii")
    except UnicodeError:
        return ""
    labels = host.split(".")
    if any(not label or len(label) > 63 for label in labels) or len(host) > 253:
        return ""
    txid = int.from_bytes(os.urandom(2), "big")
    header = struct.pack(">HHHHHH", txid, 0x0100, 1, 0, 0, 0)
    qname = b"".join(bytes([len(label)]) + label.encode("ascii") for label in labels) + b"\x00"
    packet = header + qname + struct.pack(">HH", 1, 1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(packet, (server, 53))
        data, _ = sock.recvfrom(512)
    except OSError:
        return ""
    finally:
        sock.close()
    if len(data) < 12:
        return ""
    recv_id, _flags, qdcount, ancount, _nscount, _arcount = struct.unpack(">HHHHHH", data[:12])
    if recv_id != txid or ancount <= 0:
        return ""
    offset = 12
    try:
        for _ in range(qdcount):
            offset = _skip_dns_name(data, offset)
            offset += 4
        for _ in range(ancount):
            offset = _skip_dns_name(data, offset)
            if offset + 10 > len(data):
                return ""
            rtype, rclass, _ttl, rdlength = struct.unpack(">HHIH", data[offset : offset + 10])
            offset += 10
            rdata = data[offset : offset + rdlength]
            offset += rdlength
            if rtype == 1 and rclass == 1 and rdlength == 4 and len(rdata) == 4:
                return socket.inet_ntoa(rdata)
    except (ValueError, struct.error):
        return ""
    return ""


def tailscale_override_ip(host: str) -> str:
    """IP for a ``*.ts.net`` name when system DNS cannot resolve it.

    Returns ``""`` when the host is not a Tailscale MagicDNS name, is already
    an IP, or when the OS resolver already answers. Callers then keep the
    original URL and let the HTTP stack fail in the usual way.
    """
    hostname = str(host or "").strip().rstrip(".").lower()
    if not hostname.endswith(".ts.net") or _is_literal_ip(hostname):
        return ""
    try:
        socket.getaddrinfo(hostname, None, socket.AF_INET, socket.SOCK_STREAM)
        return ""
    except OSError:
        return dns_query_a(hostname)


def _url_with_host_replaced(url: str, ip: str) -> str:
    """Rewrite ``url`` so the host is ``ip``, keeping scheme, port, and path."""
    parsed = urllib.parse.urlsplit(url)
    hostname = parsed.hostname or ""
    if not hostname or hostname == ip:
        return url
    if ":" in ip and not ip.startswith("["):
        hostport = f"[{ip}]:{parsed.port}" if parsed.port else f"[{ip}]"
    else:
        hostport = f"{ip}:{parsed.port}" if parsed.port else ip
    return urllib.parse.urlunsplit((parsed.scheme, hostport, parsed.path, parsed.query, parsed.fragment))


class _SNIHTTPSConnection(http.client.HTTPSConnection):
    """HTTPS connection that talks to an IP while verifying the original host."""

    def __init__(self, host: str, *args: Any, server_hostname: str = "", **kwargs: Any) -> None:
        super().__init__(host, *args, **kwargs)
        self._server_hostname = server_hostname

    def connect(self) -> None:
        sock = socket.create_connection((self.host, self.port), self.timeout, self.source_address)
        context = self._context or ssl.create_default_context()
        self.sock = context.wrap_socket(sock, server_hostname=self._server_hostname or self.host)


class _SNIHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, server_hostname: str) -> None:
        super().__init__()
        self._server_hostname = server_hostname

    def https_open(self, req):  # type: ignore[no-untyped-def]
        return self.do_open(self._connection, req)

    def _connection(self, host, **kwargs):  # type: ignore[no-untyped-def]
        return _SNIHTTPSConnection(host, server_hostname=self._server_hostname, **kwargs)


def _urlopen(request: urllib.request.Request, timeout: int, sni_hostname: str = ""):
    """``urlopen`` that can verify TLS against ``sni_hostname`` after an IP rewrite."""
    parsed = urllib.parse.urlsplit(request.full_url)
    host = parsed.hostname or ""
    if sni_hostname and parsed.scheme == "https" and _is_literal_ip(host):
        opener = urllib.request.build_opener(_SNIHTTPSHandler(sni_hostname))
        return opener.open(request, timeout=timeout)
    return urllib.request.urlopen(request, timeout=timeout)


def _build_multipart(
    fields: dict[str, str],
    filename: str,
    content_type: str,
    file_data: bytes,
) -> tuple[bytes, str]:
    """Serialize one multipart/form-data body for the urllib upload fallback."""
    boundary = f"----airtype{uuid.uuid4().hex}"
    lines: list[str] = []
    for name, value in fields.items():
        lines.extend(
            [
                f"--{boundary}",
                f'Content-Disposition: form-data; name="{name}"',
                "",
                value,
            ]
        )
    lines.extend(
        [
            f"--{boundary}",
            f'Content-Disposition: form-data; name="assetData"; filename="{filename}"',
            f"Content-Type: {content_type}",
            "",
        ]
    )
    head = "\r\n".join(lines).encode("utf-8")
    tail = f"\r\n--{boundary}--\r\n".encode("utf-8")
    return head + file_data + tail, f"multipart/form-data; boundary={boundary}"


def _build_curl_mime(
    fields: dict[str, str],
    filename: str,
    content_type: str,
    file_data: bytes,
) -> "CurlMime":
    """Build a ``curl_cffi`` multipart body; the sibling of :func:`_build_multipart`.

    curl_cffi's ``requests`` API does not accept the ``files=`` keyword (it
    raises ``NotImplementedError``), so uploads must pass a ``CurlMime``
    through the ``multipart=`` parameter instead. Every form field and the
    binary asset become MIME parts here, which means callers must not pass
    ``data=`` alongside ``multipart=`` (curl_cffi would re-add ``data`` dict
    entries as duplicate parts).
    """
    from curl_cffi import CurlMime

    mime = CurlMime()
    for name, value in fields.items():
        mime.addpart(name=name, data=value.encode("utf-8"))
    mime.addpart(
        name="assetData",
        filename=filename,
        content_type=content_type,
        data=file_data,
    )
    return mime


class ImmichClient:
    """Small wrapper around the Immich endpoints AirType needs.

    Every method raises :class:`ImmichError` on transport or API failures.
    Requests prefer curl-cffi (already a WebUI dependency) and fall back to
    urllib so the module keeps working in stripped-down environments.
    """

    def __init__(self, server_url: str, api_key: str, timeout_seconds: int = 60) -> None:
        self.server_url = str(server_url or "").strip().rstrip("/")
        self.api_key = str(api_key or "").strip()
        self.timeout_seconds = timeout_seconds
        self._tailscale_ip: Optional[str] = None

    @property
    def configured(self) -> bool:
        return bool(self.server_url and self.api_key)

    # ------------------------------------------------------------------ #
    # Transport helpers                                                   #
    # ------------------------------------------------------------------ #

    def _auth_headers(self) -> dict[str, str]:
        return {"x-api-key": self.api_key}

    def _parsed_server(self) -> urllib.parse.SplitResult:
        return urllib.parse.urlsplit(self.server_url)

    def _override_ip(self) -> str:
        """Cached MagicDNS IP, or ``""`` when the original host is fine."""
        if self._tailscale_ip is not None:
            return self._tailscale_ip
        host = self._parsed_server().hostname or ""
        self._tailscale_ip = tailscale_override_ip(host)
        return self._tailscale_ip

    def _curl_options(self) -> dict[Any, Any]:
        ip = self._override_ip()
        if not ip:
            return {}
        parsed = self._parsed_server()
        host = (parsed.hostname or "").rstrip(".")
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        from curl_cffi.const import CurlOpt

        return {CurlOpt.RESOLVE: [f"{host}:{port}:{ip}"]}

    def _urllib_url(self, url: str) -> str:
        ip = self._override_ip()
        return _url_with_host_replaced(url, ip) if ip else url

    def _urllib_headers(self, headers: dict[str, str]) -> dict[str, str]:
        if not self._override_ip():
            return headers
        out = dict(headers)
        out["Host"] = self._parsed_server().netloc.split("@")[-1]
        return out

    def _urllib_exchange(
        self,
        method: str,
        url: str,
        headers: dict[str, str],
        body: Optional[bytes],
        *,
        error_prefix: str,
        curl_error: Optional[BaseException] = None,
    ) -> tuple[int, str]:
        request = urllib.request.Request(
            self._urllib_url(url),
            data=body,
            headers=self._urllib_headers(headers),
            method=method,
        )
        sni = (self._parsed_server().hostname or "").rstrip(".")
        try:
            with _urlopen(request, self.timeout_seconds, sni_hostname=sni) as response:
                return response.status, response.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as error:
            return error.code, error.read().decode("utf-8", errors="replace")
        except Exception as error:
            if curl_error is not None and not isinstance(curl_error, ImportError):
                raise ImmichError(f"{error_prefix}: {curl_error}") from curl_error
            raise ImmichError(f"{error_prefix}: {error}") from error

    def _request_json(self, method: str, path: str, payload: dict[str, Any]) -> tuple[int, Any]:
        """Send a JSON request and return ``(http_status, parsed_body)``."""
        if not self.configured:
            raise ImmichError("Immich server_url and api_key must be configured.")
        url = f"{self.server_url}{path}"
        body = json.dumps(payload).encode("utf-8")
        headers = self._auth_headers()
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json"
        try:
            curl_requests = _curl_requests()
            kwargs: dict[str, Any] = {
                "headers": headers,
                "data": body,
                "timeout": self.timeout_seconds,
            }
            curl_options = self._curl_options()
            if curl_options:
                kwargs["curl_options"] = curl_options
            response = curl_requests.request(method, url, **kwargs)
            status = response.status_code
            text = response.text
        except ImmichError:
            raise
        except Exception as error:
            status, text = self._urllib_exchange(
                method, url, headers, body, error_prefix="Immich request failed", curl_error=error
            )

        parsed: Any = {}
        if text:
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError:
                parsed = {}
        if status >= 400:
            raise ImmichError(f"Immich {method} {path} failed with {status}: {text[:300]}")
        return status, parsed


    # ------------------------------------------------------------------ #
    # Assets                                                              #
    # ------------------------------------------------------------------ #

    def upload_asset(
        self,
        *,
        data: bytes,
        filename: str,
        content_type: str,
        device_asset_id: str,
        file_created_at: str,
        device_id: str = "airtype",
    ) -> dict[str, Any]:
        """Upload one binary asset.

        Returns ``{"id", "status", "duplicate"}``. Immich answers a
        checksum duplicate with HTTP 200 and ``status: duplicate``; the
        returned id is the existing asset, which callers should reuse.
        """
        if not self.configured:
            raise ImmichError("Immich server_url and api_key must be configured.")
        checksum = hashlib.sha1(data).hexdigest()
        url = f"{self.server_url}/api/assets"
        fields = {
            "deviceAssetId": device_asset_id,
            "deviceId": device_id,
            "fileCreatedAt": file_created_at,
            "fileModifiedAt": file_created_at,
        }
        headers = self._auth_headers()
        headers["X-Immich-Checksum"] = checksum
        try:
            curl_requests = _curl_requests()
            # curl_cffi does not support ``files=``; build the multipart body
            # explicitly with CurlMime and pass it via ``multipart=``. All
            # form fields are added as MIME parts, so ``data=`` must stay unset.
            kwargs: dict[str, Any] = {
                "headers": headers,
                "multipart": _build_curl_mime(fields, filename, content_type, data),
                "timeout": self.timeout_seconds,
            }
            curl_options = self._curl_options()
            if curl_options:
                kwargs["curl_options"] = curl_options
            response = curl_requests.post(url, **kwargs)
            status = response.status_code
            text = response.text
        except ImmichError:
            raise
        except Exception as error:
            body, content_type_header = _build_multipart(fields, filename, content_type, data)
            urllib_headers = dict(headers)
            urllib_headers["Content-Type"] = content_type_header
            status, text = self._urllib_exchange(
                "POST",
                url,
                urllib_headers,
                body,
                error_prefix="Immich upload failed",
                curl_error=error,
            )

        parsed: dict[str, Any] = {}
        if text:
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError:
                parsed = {}
        if status >= 400:
            raise ImmichError(f"Immich upload failed with {status}: {text[:300]}")
        asset_id = str(parsed.get("id") or "")
        if not asset_id:
            raise ImmichError(f"Immich upload response did not contain an asset id: {text[:300]}")
        return {
            "id": asset_id,
            "status": str(parsed.get("status") or "created"),
            "duplicate": status == 200,
        }


    # ------------------------------------------------------------------ #
    # Tags                                                                #
    # ------------------------------------------------------------------ #

    def ensure_tag(self, name: str) -> str:
        """Create the tag or return the id of the existing one (idempotent)."""
        status, body = self._request_json("POST", "/api/tags", {"name": name})
        tag_id = str((body or {}).get("id") or "")
        if not tag_id:
            raise ImmichError(f"Immich tag response did not contain an id: {json.dumps(body)[:200]}")
        return tag_id

    def tag_assets(self, tag_id: str, asset_ids: list[str]) -> None:
        """Attach assets to a tag in one batch.

        Immich v2+ exposes this as ``PUT /api/tags/{id}/assets`` with
        ``{"ids": [...]}``. Older docs used POST + ``assetIds``; that route
        404s on current servers (Nest: "Cannot POST /api/tags/.../assets").
        """
        if not asset_ids:
            return
        self._request_json("PUT", f"/api/tags/{tag_id}/assets", {"ids": list(asset_ids)})

    # ------------------------------------------------------------------ #
    # Albums                                                              #
    # ------------------------------------------------------------------ #

    def create_album(self, album_name: str, asset_ids: list[str]) -> str:
        """Create an album that contains the given assets; returns its id."""
        status, body = self._request_json(
            "POST", "/api/albums", {"albumName": album_name, "assetIds": list(asset_ids)}
        )
        album_id = str((body or {}).get("id") or "")
        if not album_id:
            raise ImmichError(f"Immich album response did not contain an id: {json.dumps(body)[:200]}")
        return album_id

    # ------------------------------------------------------------------ #
    # Sharing                                                             #
    # ------------------------------------------------------------------ #

    def create_shared_link(
        self,
        asset_ids: list[str],
        *,
        allow_download: bool = False,
        description: str = "",
    ) -> dict[str, str]:
        """Create one passwordless INDIVIDUAL shared link for the assets."""
        payload: dict[str, Any] = {
            "type": "INDIVIDUAL",
            "assetIds": list(asset_ids),
            "allowDownload": bool(allow_download),
        }
        if description:
            payload["description"] = description
        status, body = self._request_json("POST", "/api/shared-links", payload)
        key = str((body or {}).get("key") or "")
        if not key:
            raise ImmichError(f"Immich shared-link response did not contain a key: {json.dumps(body)[:200]}")
        return {"key": key, "share_url": f"{self.server_url}/share/{key}"}

    def asset_thumbnail_url(self, asset_id: str, share_key: str, size: str = "preview") -> str:
        """Public, key-gated thumbnail URL suitable for inline image rendering."""
        query = urllib.parse.urlencode({"key": share_key, "size": size})
        return f"{self.server_url}/api/assets/{asset_id}/thumbnail?{query}"

    def asset_original_url(self, asset_id: str, share_key: str) -> str:
        """Public, key-gated original-file URL."""
        query = urllib.parse.urlencode({"key": share_key})
        return f"{self.server_url}/api/assets/{asset_id}/original?{query}"