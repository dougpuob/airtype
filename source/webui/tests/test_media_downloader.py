"""Tests for yt-dlp YouTube JS runtime detection and failure hints."""

import unittest
from unittest.mock import patch

from app import main as webui


class MediaDownloaderJsRuntimeTests(unittest.TestCase):
    def setUp(self) -> None:
        webui._find_js_runtime.cache_clear()

    def tearDown(self) -> None:
        webui._find_js_runtime.cache_clear()

    def test_parse_version_tuple(self) -> None:
        self.assertEqual(webui._parse_version_tuple("deno 2.8.1 (stable)"), (2, 8, 1))
        self.assertEqual(webui._parse_version_tuple("v26.5.1"), (26, 5, 1))
        self.assertIsNone(webui._parse_version_tuple("no version here"))

    def test_js_runtime_args_pass_absolute_deno_path(self) -> None:
        webui._find_js_runtime.cache_clear()
        with patch.object(webui, "_find_js_runtime", return_value=("deno", "/opt/homebrew/bin/deno")):
            self.assertEqual(
                webui._media_downloader_js_runtime_args(),
                ["--js-runtimes", "deno:/opt/homebrew/bin/deno"],
            )

    def test_js_runtime_args_empty_when_missing(self) -> None:
        with patch.object(webui, "_find_js_runtime", return_value=None):
            self.assertEqual(webui._media_downloader_js_runtime_args(), [])

    def test_find_js_runtime_prefers_usable_deno_over_node(self) -> None:
        with (
            patch.object(
                webui,
                "_iter_js_runtime_paths",
                side_effect=lambda name: {
                    "deno": ["/opt/homebrew/bin/deno"],
                    "node": ["/opt/homebrew/bin/node"],
                }[name],
            ),
            patch.object(webui, "_js_runtime_version_ok", return_value=True),
        ):
            self.assertEqual(webui._find_js_runtime(), ("deno", "/opt/homebrew/bin/deno"))

    def test_missing_js_runtime_hint_tells_user_to_install_deno(self) -> None:
        with patch.object(webui, "_find_js_runtime", return_value=None):
            hint = webui._media_downloader_failure_hint(
                "https://www.youtube.com/watch?v=abc",
                "WARNING: [youtube] No supported JavaScript runtime could be found. "
                "See https://github.com/yt-dlp/yt-dlp/wiki/EJS for details "
                "ERROR: unable to download video data: HTTP Error 403: Forbidden",
            )
        self.assertIn("brew install deno", hint)
        self.assertIn("does not replace the JavaScript runtime", hint)
        self.assertNotIn("cookies_from_browser", hint)

    def test_youtube_403_with_runtime_explains_cdn_rejection(self) -> None:
        with patch.object(webui, "_find_js_runtime", return_value=("deno", "/opt/homebrew/bin/deno")):
            hint = webui._media_downloader_failure_hint(
                "https://youtu.be/abc",
                "ERROR: unable to download video data: HTTP Error 403: Forbidden",
            )
        self.assertIn("media CDN URL", hint)
        self.assertIn("player_client=mweb", hint)
        self.assertIn("[webui.yt-dlp]", hint)
        self.assertNotIn("brew install deno", hint)

    def test_youtube_args_check_formats_and_mweb_client(self) -> None:
        args = webui._media_downloader_youtube_args("https://www.youtube.com/watch?v=abc")
        self.assertIn("--check-formats", args)
        self.assertIn("youtube:player_client=default,mweb", args)
        preview_args = webui._media_downloader_youtube_args(
            "https://youtu.be/abc",
            download=False,
        )
        self.assertNotIn("--check-formats", preview_args)
        self.assertEqual(
            webui._media_downloader_youtube_args("https://www.bilibili.com/video/BV1"),
            [],
        )

    def test_youtube_does_not_use_impersonate(self) -> None:
        with patch.object(webui, "_best_impersonate_target", return_value="chrome-136:macos-15"):
            self.assertEqual(
                webui._media_downloader_browser_args(("yt-dlp",), "https://www.youtube.com/watch?v=abc"),
                [],
            )
            self.assertEqual(
                webui._media_downloader_browser_args(("yt-dlp",), "https://www.bilibili.com/video/BV1"),
                ["--impersonate", "chrome-136:macos-15"],
            )

    def test_env_prepends_homebrew_when_missing_from_path(self) -> None:
        with (
            patch.object(webui.os.path, "isdir", return_value=True),
            patch.dict(webui.os.environ, {"PATH": "/usr/bin:/bin"}, clear=False),
        ):
            env = webui._media_downloader_env()
        self.assertTrue(env["PATH"].startswith("/opt/homebrew/bin:"))
        self.assertIn("/usr/bin", env["PATH"])


if __name__ == "__main__":
    unittest.main()
