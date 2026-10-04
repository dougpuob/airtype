"""Tests for the Immich REST API client."""

import json
import re
import socket
import struct
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest.mock import patch

from curl_cffi import CurlMime

from app import immich
from app.immich import ImmichClient, ImmichError, dns_query_a, tailscale_override_ip


class _FakeResponse:
    def __init__(self, status_code: int = 200, body: dict | None = None) -> None:
        self.status_code = status_code
        self._text = json.dumps(body or {})

    @property
    def text(self) -> str:
        return self._text


class ImmichClientTests(unittest.TestCase):
    def test_unconfigured_client_raises(self) -> None:
        client = ImmichClient("", "key")
        self.assertFalse(client.configured)
        with self.assertRaises(ImmichError):
            client.ensure_tag("abc")

    def test_upload_created(self) -> None:
        client = ImmichClient("https://immich.example", "key")
        with patch(
            "curl_cffi.requests.post",
            return_value=_FakeResponse(201, {"id": "asset-1", "status": "created"}),
        ) as mock_post:
            result = client.upload_asset(
                data=b"binary",
                filename="img-0.png",
                content_type="image/png",
                device_asset_id="guid-0-abc",
                file_created_at="2026-10-04T12:00:00Z",
            )
        self.assertEqual(result, {"id": "asset-1", "status": "created", "duplicate": False})
        kwargs = mock_post.call_args.kwargs
        self.assertEqual(kwargs["headers"]["X-Immich-Checksum"], immich.hashlib.sha1(b"binary").hexdigest())
        self.assertNotIn("files", kwargs)
        self.assertNotIn("data", kwargs)
        self.assertIsInstance(kwargs["multipart"], CurlMime)

    def test_upload_duplicate_reuses_asset(self) -> None:
        client = ImmichClient("https://immich.example", "key")
        with patch(
            "curl_cffi.requests.post",
            return_value=_FakeResponse(200, {"id": "asset-9", "status": "duplicate"}),
        ):
            result = client.upload_asset(
                data=b"binary",
                filename="a.png",
                content_type="image/png",
                device_asset_id="x",
                file_created_at="2026-10-04T12:00:00Z",
            )
        self.assertTrue(result["duplicate"])
        self.assertEqual(result["id"], "asset-9")

    def test_ensure_tag_and_tag_assets(self) -> None:
        client = ImmichClient("https://immich.example", "key")
        with patch(
            "curl_cffi.requests.request",
            side_effect=[
                _FakeResponse(201, {"id": "tag-1", "name": "guid"}),
                _FakeResponse(200, []),
            ],
        ) as mock_request:
            tag_id = client.ensure_tag("guid")
            client.tag_assets(tag_id, ["a1", "a2"])
        self.assertEqual(tag_id, "tag-1")
        second_call = mock_request.call_args_list[1]
        self.assertEqual(second_call.args[0], "PUT")
        self.assertTrue(str(second_call.args[1]).endswith("/api/tags/tag-1/assets"))
        second_payload = json.loads(second_call.kwargs["data"].decode("utf-8"))
        self.assertEqual(second_payload, {"ids": ["a1", "a2"]})

    def test_create_shared_link_and_urls(self) -> None:
        client = ImmichClient("https://immich.example/", "key")
        with patch("curl_cffi.requests.request", return_value=_FakeResponse(201, {"key": "thekey"})):
            link = client.create_shared_link(["a1", "a2"])
        self.assertEqual(link["key"], "thekey")
        self.assertEqual(link["share_url"], "https://immich.example/share/thekey")
        self.assertIn("/api/assets/a1/thumbnail?key=thekey&size=preview", client.asset_thumbnail_url("a1", "thekey"))
        self.assertIn("/api/assets/a1/original?key=thekey", client.asset_original_url("a1", "thekey"))

    def test_api_error_raises(self) -> None:
        client = ImmichClient("https://immich.example", "key")
        with patch("curl_cffi.requests.request", return_value=_FakeResponse(401, {"error": "nope"})):
            with self.assertRaises(ImmichError):
                client.ensure_tag("x")

    def test_missing_key_in_share_link_raises(self) -> None:
        client = ImmichClient("https://immich.example", "key")
        with patch("curl_cffi.requests.request", return_value=_FakeResponse(201, {})):
            with self.assertRaises(ImmichError):
                client.create_shared_link(["a1"])

    def test_urllib_multipart_fallback_upload(self) -> None:
        client = ImmichClient("https://immich.example", "key")
        captured: dict = {}

        class _FakeUrllibResponse:
            status = 201

            def read(self) -> bytes:
                return json.dumps({"id": "asset-urllib", "status": "created"}).encode("utf-8")

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        def fake_urlopen(request, timeout=None):
            captured["request"] = request
            return _FakeUrllibResponse()

        with (
            patch("curl_cffi.requests.post", side_effect=ImportError("no curl")),
            patch("urllib.request.urlopen", side_effect=fake_urlopen),
        ):
            result = client.upload_asset(
                data=b"abc",
                filename="a.jpg",
                content_type="image/jpeg",
                device_asset_id="d1",
                file_created_at="t",
            )

        self.assertEqual(result["id"], "asset-urllib")
        request = captured["request"]
        self.assertTrue(str(request.get_header("Content-type") or "").startswith("multipart/form-data"))
        self.assertIn(b'name="assetData"; filename="a.jpg"', request.data)
        self.assertIn(b"Content-Type: image/jpeg", request.data)

    def test_dns_query_a_parses_answer(self) -> None:
        captured: list[bytes] = []

        class _FakeDnsSocket:
            def settimeout(self, _timeout):
                return None

            def sendto(self, data, _addr):
                captured.append(data)
                return len(data)

            def recvfrom(self, _size):
                txid = int.from_bytes(captured[0][:2], "big")
                name = b"\x06immich\x07example\x03net\x00"
                header = struct.pack(">HHHHHH", txid, 0x8180, 1, 1, 0, 0)
                question = name + struct.pack(">HH", 1, 1)
                answer = struct.pack(">HHHIH", 0xC00C, 1, 1, 60, 4) + socket.inet_aton("100.116.11.98")
                return header + question + answer, ("100.100.100.100", 53)

            def close(self):
                return None

        with patch.object(immich.socket, "socket", return_value=_FakeDnsSocket()):
            self.assertEqual(dns_query_a("immich.example.net"), "100.116.11.98")

    def test_tailscale_override_skips_non_tsnet(self) -> None:
        with patch.object(immich, "dns_query_a") as mock_dns:
            self.assertEqual(tailscale_override_ip("immich.example"), "")
            mock_dns.assert_not_called()

    def test_tailscale_override_skips_when_system_dns_works(self) -> None:
        with (
            patch.object(immich.socket, "getaddrinfo", return_value=[(socket.AF_INET, 0, 0, "", ("100.1.2.3", 0))]),
            patch.object(immich, "dns_query_a") as mock_dns,
        ):
            self.assertEqual(tailscale_override_ip("immich-app.tail84298.ts.net"), "")
            mock_dns.assert_not_called()

    def test_tailscale_magicdns_adds_curl_resolve(self) -> None:
        client = ImmichClient("http://immich-app.tail84298.ts.net:2283", "key")
        with (
            patch.object(immich.socket, "getaddrinfo", side_effect=socket.gaierror("no system dns")),
            patch.object(immich, "dns_query_a", return_value="100.116.11.98"),
            patch(
                "curl_cffi.requests.request",
                return_value=_FakeResponse(201, {"id": "tag-ts", "name": "guid"}),
            ) as mock_request,
        ):
            tag_id = client.ensure_tag("guid")
        self.assertEqual(tag_id, "tag-ts")
        kwargs = mock_request.call_args.kwargs
        from curl_cffi.const import CurlOpt

        self.assertEqual(
            kwargs["curl_options"][CurlOpt.RESOLVE],
            ["immich-app.tail84298.ts.net:2283:100.116.11.98"],
        )

    def test_urllib_fallback_rewrites_tsnet_to_ip(self) -> None:
        client = ImmichClient("http://immich-app.tail84298.ts.net:2283", "key")
        captured: dict = {}

        class _FakeUrllibResponse:
            status = 201

            def read(self) -> bytes:
                return json.dumps({"id": "asset-ts", "status": "created"}).encode("utf-8")

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        def fake_urlopen(request, timeout=None, sni_hostname=""):
            captured["full_url"] = request.full_url
            captured["host"] = request.get_header("Host") or request.get_header("host")
            return _FakeUrllibResponse()

        with (
            patch.object(immich.socket, "getaddrinfo", side_effect=socket.gaierror("no system dns")),
            patch.object(immich, "dns_query_a", return_value="100.116.11.98"),
            patch("curl_cffi.requests.post", side_effect=ImportError("no curl")),
            patch.object(immich, "_urlopen", side_effect=fake_urlopen),
        ):
            result = client.upload_asset(
                data=b"abc",
                filename="a.jpg",
                content_type="image/jpeg",
                device_asset_id="d1",
                file_created_at="t",
            )

        self.assertEqual(result["id"], "asset-ts")
        self.assertEqual(captured["full_url"], "http://100.116.11.98:2283/api/assets")
        self.assertEqual(captured["host"], "immich-app.tail84298.ts.net:2283")


def _parse_multipart(body: bytes, boundary: bytes) -> dict:
    """Parse a multipart/form-data body into ``{name: {filename, content_type, payload}}``."""
    parts: dict = {}
    for raw in body.split(b"--" + boundary):
        if raw in (b"", b"--", b"--\r\n"):
            continue
        if raw.startswith(b"\r\n"):
            raw = raw[2:]
        if raw.endswith(b"\r\n"):
            raw = raw[:-2]
        headers_blob, separator, payload = raw.partition(b"\r\n\r\n")
        if not separator:
            continue
        headers = {}
        for line in headers_blob.split(b"\r\n"):
            key, _, value = line.partition(b":")
            headers[key.strip().lower()] = value.strip()
        disposition = headers.get(b"content-disposition", b"")
        name_match = re.search(rb'name="([^"]*)"', disposition)
        filename_match = re.search(rb'filename="([^"]*)"', disposition)
        field = name_match.group(1).decode("utf-8") if name_match else ""
        parts[field] = {
            "filename": filename_match.group(1).decode("utf-8") if filename_match else "",
            "content_type": headers.get(b"content-type", b"").decode("utf-8"),
            "payload": payload,
        }
    return parts


class ImmichUploadMultipartTests(unittest.TestCase):
    """End-to-end checks that a real request carries Immich's multipart shape."""

    def test_upload_multipart_body_via_local_server(self) -> None:
        captured: dict = {}

        class _Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length") or 0)
                captured["content_type"] = self.headers.get("Content-Type") or ""
                captured["checksum"] = self.headers.get("X-Immich-Checksum") or ""
                captured["body"] = self.rfile.read(length)
                payload = json.dumps({"id": "asset-e2e", "status": "created"}).encode("utf-8")
                self.send_response(201)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args) -> None:
                pass

        server = HTTPServer(("127.0.0.1", 0), _Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            client = ImmichClient(
                f"http://127.0.0.1:{server.server_port}", "key", timeout_seconds=10
            )
            result = client.upload_asset(
                data=b"file-bytes",
                filename="img-0.png",
                content_type="image/png",
                device_asset_id="guid-0-abc",
                file_created_at="2026-10-04T12:00:00Z",
            )
        finally:
            server.shutdown()
            server.server_close()

        self.assertEqual(result, {"id": "asset-e2e", "status": "created", "duplicate": False})
        self.assertEqual(captured["checksum"], immich.hashlib.sha1(b"file-bytes").hexdigest())
        content_type = str(captured["content_type"])
        self.assertTrue(content_type.startswith("multipart/form-data; boundary="))
        boundary = content_type.split("boundary=", 1)[1].encode("utf-8")
        parts = _parse_multipart(captured["body"], boundary)
        self.assertEqual(parts["deviceAssetId"]["payload"], b"guid-0-abc")
        self.assertEqual(parts["deviceId"]["payload"], b"airtype")
        self.assertEqual(parts["fileCreatedAt"]["payload"], b"2026-10-04T12:00:00Z")
        self.assertEqual(parts["fileModifiedAt"]["payload"], b"2026-10-04T12:00:00Z")
        self.assertEqual(parts["assetData"]["filename"], "img-0.png")
        self.assertEqual(parts["assetData"]["content_type"], "image/png")
        self.assertEqual(parts["assetData"]["payload"], b"file-bytes")


if __name__ == "__main__":
    unittest.main()