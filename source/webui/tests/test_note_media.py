"""Tests for the shared note-media Immich pipeline."""

import unittest
import uuid
from unittest.mock import patch

from app import web_article


class _FakeImmich:
    def __init__(self, server_url, api_key, timeout_seconds=60):
        self.server_url = server_url
        self.api_key = api_key
        self.configured = bool(server_url and api_key)
        self.uploaded = []
        self.tagged = None

    def upload_asset(self, *, data, filename, content_type, device_asset_id, file_created_at, device_id="airtype"):
        asset_id = f"a{len(self.uploaded)}"
        self.uploaded.append(
            {"filename": filename, "device_asset_id": device_asset_id, "size": len(data)}
        )
        return {"id": asset_id, "status": "created", "duplicate": False}

    def ensure_tag(self, name):
        return "tag-1"

    def tag_assets(self, tag_id, asset_ids):
        self.tagged = (tag_id, list(asset_ids))

    def create_shared_link(self, asset_ids, *, allow_download=False, description=""):
        return {"key": "K", "share_url": "https://immich.example/share/K"}

    def asset_thumbnail_url(self, asset_id, share_key, size="preview"):
        return f"https://immich.example/api/assets/{asset_id}/thumbnail?key={share_key}&size={size}"

    def create_album(self, album_name, asset_ids):
        return "album-1"


class _SyncExecutor:
    def submit(self, fn, *args, **kwargs):
        fn(*args, **kwargs)


class StoreNoteMediaTests(unittest.TestCase):
    def test_success_uploads_tags_shares_and_maps(self) -> None:
        with (
            patch.object(
                web_article,
                "download_image",
                side_effect=[(b"png-bytes", "image/png"), (b"jpg-bytes", "image/jpeg")],
            ),
            patch.object(web_article, "ImmichClient", _FakeImmich),
        ):
            result = web_article.store_note_media(
                ["https://cdn.example.com/a.png", "https://cdn.example.com/b.jpg"],
                source_url="https://example.com/post/1",
                guid=str(uuid.uuid4()),
                title="測試",
                immich_server_url="https://immich.example",
                immich_api_key="immich-key",
            )
        self.assertEqual(result["share_url"], "https://immich.example/share/K")
        self.assertEqual([item["status"] for item in result["images"]], ["uploaded", "uploaded"])
        self.assertEqual(
            result["images"][0]["embedded_url"],
            "https://immich.example/api/assets/a0/thumbnail?key=K&size=preview",
        )
        self.assertEqual(
            result["images"][1]["embedded_url"],
            "https://immich.example/api/assets/a1/thumbnail?key=K&size=preview",
        )
        self.assertEqual(result["warnings"], [])

    def test_empty_urls_short_circuits(self) -> None:
        result = web_article.store_note_media(
            [],
            guid=str(uuid.uuid4()),
            immich_server_url="https://immich.example",
            immich_api_key="immich-key",
        )
        self.assertEqual(result, {"images": [], "share_url": "", "album_id": "", "warnings": []})

    def test_unconfigured_client_keeps_original_links(self) -> None:
        with patch.object(web_article, "ImmichClient", _FakeImmich):
            result = web_article.store_note_media(
                ["https://cdn.example.com/a.png"],
                guid=str(uuid.uuid4()),
            )
        # Same behavior as the original web-article job: when Immich is not
        # configured the loop skips uploads entirely and only a warning is
        # reported, so every link stays original.
        self.assertEqual(result["images"], [])
        self.assertEqual(result["share_url"], "")
        self.assertTrue(any("尚未設定 Immich" in warning for warning in result["warnings"]))

    def test_download_failure_keeps_original_link_with_warning(self) -> None:
        with (
            patch.object(web_article, "download_image", side_effect=RuntimeError("下載失敗")),
            patch.object(web_article, "ImmichClient", _FakeImmich),
        ):
            result = web_article.store_note_media(
                ["https://cdn.example.com/a.png"],
                guid=str(uuid.uuid4()),
                immich_server_url="https://immich.example",
                immich_api_key="immich-key",
            )
        self.assertEqual(result["images"][0]["status"], "remote")
        self.assertIn("下載失敗", result["images"][0]["warning"])
        self.assertEqual(result["share_url"], "")


class StartJobGuidTests(unittest.TestCase):
    def test_client_guid_is_kept(self) -> None:
        guid = str(uuid.uuid4())
        with (
            patch.object(web_article, "_get_executor", return_value=_SyncExecutor()),
            patch.object(web_article, "fetch_markdown", return_value="# 標題"),
            patch.object(web_article, "ImmichClient", _FakeImmich),
        ):
            payload = web_article.start_job(
                "https://example.com/article",
                guid=guid,
                immich_server_url="https://immich.example",
                immich_api_key="immich-key",
            )
        self.assertEqual(payload["guid"], guid)

    def test_invalid_guid_rejected(self) -> None:
        with self.assertRaises(ValueError):
            web_article.start_job("https://example.com/article", guid="not-a-uuid")

    def test_missing_guid_generated(self) -> None:
        with (
            patch.object(web_article, "_get_executor", return_value=_SyncExecutor()),
            patch.object(web_article, "fetch_markdown", return_value="# 標題"),
            patch.object(web_article, "ImmichClient", _FakeImmich),
        ):
            payload = web_article.start_job(
                "https://example.com/article",
                immich_server_url="https://immich.example",
                immich_api_key="immich-key",
            )
        uuid.UUID(payload["guid"])


if __name__ == "__main__":
    unittest.main()