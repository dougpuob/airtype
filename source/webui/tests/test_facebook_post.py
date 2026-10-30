"""Facebook posts go through Capture Post: post text, photos to Immich, Whisper for videos."""

from unittest.mock import patch
import json
import tempfile
import unittest

from app import clip_pipeline
from app import clip_requests
from app import facebook_post
from app import known_sources
from app import main as webui


SHARE_URL = "https://www.facebook.com/share/p/1Cf35dUwuX/"
GROUP_POST = "https://www.facebook.com/groups/hikers/permalink/4726654250936935/?rdid=abc&share_url=x"
CANONICAL = "https://www.facebook.com/groups/hikers/posts/4726654250936935/"
PHOTO_1 = "https://scontent.xx.fbcdn.net/v/t39/p1_n.jpg?stp=big"
PHOTO_1_SMALL = "https://scontent.xx.fbcdn.net/v/t39/p1_s.jpg?stp=small"
PHOTO_2 = "https://scontent.xx.fbcdn.net/v/t39/p2_n.jpg?stp=big"
VIDEO_HD = "https://video.xx.fbcdn.net/o1/v/t2/f2/m266/hd.mp4?efg=1"
VIDEO_SD = "https://video.xx.fbcdn.net/o1/v/t2/f2/m412/sd.mp4?efg=2"
SETTINGS = {"web_to_markdown": {}, "immich": {}, "capture_post": {"ai_title_enabled": False}}


def _page(*blocks, og_url: str = CANONICAL, title: str = "Hikers | post") -> str:
    scripts = "".join(
        f'<script type="application/json" data-sjs>{json.dumps(block)}</script>' for block in blocks
    )
    return (
        f'<html><head><title>{title}</title><meta property="og:url" content="{og_url}" />'
        f'<meta property="og:title" content="{title}" /></head><body>{scripts}</body></html>'
    )


def _photo(photo_id: str, uri: str, width: int, key: str = "viewer_image") -> dict:
    return {"__typename": "Photo", "id": photo_id, key: {"uri": uri, "width": width, "height": width}}


ALBUM_STORY = {
    "__typename": "Story",
    "id": "UzpfSTEw",
    "post_id": "4726654250936935",
    "actors": [{"__typename": "User", "name": "Luo"}],
    "to": {"__typename": "Group", "name": "Hikers"},
    "attachments": [{
        "styles": {"attachment": {
            "frame_sublayout_subattachments": {"count": 5, "nodes": [{"media": {"__typename": "Photo", "id": "1"}}]},
            "two_photos_subattachments": {"nodes": [
                {"media": _photo("1", PHOTO_1_SMALL, 320, key="image")},
                {"media": _photo("1", PHOTO_1, 1542)},
                {"media": _photo("2", PHOTO_2, 1542)},
            ]},
        }},
    }],
    "comet_sections": {
        "content": {"story": {"message": {"text": "【Cloud forest】\nWent hiking http://example.com/trail"}}},
        "timestamp": {"story": {"creation_time": 1793279812}},
        "feedback": {"story": {"comments": [{"__typename": "Story", "message": {"text": "a comment"}}]}},
    },
}

VIDEO_STORY = {
    "__typename": "Story",
    "post_id": "740190678139306",
    "actors": [{"__typename": "Page", "name": "ATTN:"}],
    "attachments": [{"styles": {"attachment": {"media": {
        "__typename": "Video",
        "id": "6968553779868435",
        "audio_availability": "AVAILABLE",
        "videoDeliveryLegacyFields": {
            "id": "6968553779868435",
            "browser_native_sd_url": VIDEO_SD,
            "browser_native_hd_url": VIDEO_HD,
        },
    }}}}],
    "comet_sections": {"content": {"story": {"message": {"text": "Learning new skills is hard"}}}},
}

REEL_BLOCK = {"data": {"video": {"creation_story": {
    "post_id": "3030737660579682",
    "message": {"text": "Reel caption"},
    "attachments": [{"media": {"__typename": "Video", "id": "1195289147628387"}}],
    "short_form_video_context": {"video_owner": {"__typename": "User", "name": "Beast Camp"}},
}}, "viewer": {"lasso_blue_feed": {"edges": [{"node": {
    "__typename": "Story", "post_id": "999", "message": {"text": "other reel"}, "attachments": [],
}}]}}}}


class FacebookUrlTests(unittest.TestCase):
    def test_post_urls(self) -> None:
        for url in (
            SHARE_URL,
            "https://www.facebook.com/share/v/1AbCdE/",
            "https://m.facebook.com/share/r/1AbCdE",
            "https://www.facebook.com/dougpuob/posts/pfbid02mDZxLuefPWiBWoLdkRvJ4",
            "https://www.facebook.com/dougpuob/posts/some-slug/10222852645757660/",
            GROUP_POST,
            "https://www.facebook.com/groups/1645456212344334/posts/3737828833107051/",
            "https://www.facebook.com/permalink.php?story_fbid=pfbid0fq&id=100068861234290",
            "https://www.facebook.com/story.php?story_fbid=123456789&id=100073071055552",
            "https://www.facebook.com/photo/?fbid=10222852578635982&set=a.1",
            "https://www.facebook.com/cnn/videos/10155529876156509/",
            "https://www.facebook.com/reel/1195289147628387",
            "https://www.facebook.com/watch/?v=647537299265662",
            "https://fb.watch/abcDEF123/",
        ):
            self.assertTrue(facebook_post.is_facebook_post_url(url), url)
            self.assertEqual(known_sources.route_for_url(url), "capture-post", url)

    def test_non_post_pages_stay_on_web_article(self) -> None:
        for url in (
            "https://www.facebook.com/groups/1632817630320628/user/100000366204205/",
            "https://www.facebook.com/dougpuob",
            "https://www.facebook.com/groups/worriorrock/",
            "https://www.facebook.com/watch/",
            "https://www.facebook.com/permalink.php",
            "https://notfacebook.com/share/p/1Cf35dUwuX/",
        ):
            self.assertFalse(facebook_post.is_facebook_post_url(url), url)
            self.assertEqual(known_sources.route_for_url(url), "web-article", url)

    def test_clean_url_drops_tracking(self) -> None:
        self.assertEqual(facebook_post.clean_url(GROUP_POST), "https://www.facebook.com/groups/hikers/permalink/4726654250936935/")
        self.assertEqual(
            facebook_post.clean_url("https://m.facebook.com/permalink.php?story_fbid=1&id=2&ref=x"),
            "https://www.facebook.com/permalink.php?story_fbid=1&id=2",
        )


class FacebookIdentityTests(unittest.TestCase):
    def test_text_slug_is_dropped_from_identity(self) -> None:
        self.assertEqual(
            facebook_post.identity_url_for("https://www.facebook.com/dougpuob/posts/%E6%98%8E-coscup/10222852645757660/"),
            "https://www.facebook.com/dougpuob/posts/10222852645757660",
        )
        self.assertEqual(
            facebook_post.identity_url_for("https://www.facebook.com/groups/hikers/posts/4726654250936935/"),
            "https://www.facebook.com/groups/hikers/posts/4726654250936935",
        )
        self.assertEqual(facebook_post.identity_url_for(""), "")


class ParseFacebookPageTests(unittest.TestCase):
    def test_album_post_text_photos_and_hidden_count(self) -> None:
        fields = facebook_post.parse_post_html(_page({"data": {"node_v2": ALBUM_STORY}}), GROUP_POST)
        self.assertEqual(fields["text"], "【Cloud forest】\nWent hiking http://example.com/trail")
        self.assertEqual(fields["author"], "Luo")
        self.assertEqual(fields["group"], "Hikers")
        self.assertEqual(fields["image_urls"], [PHOTO_1, PHOTO_2])
        self.assertEqual(fields["photo_count"], 5)
        self.assertEqual(fields["published"], "2026-10-29T13:16:52+00:00")
        markdown = facebook_post.post_markdown(fields, CANONICAL)
        self.assertIn(f"![]({PHOTO_1})", markdown)
        self.assertIn("3 more photos", markdown)

    def test_video_post_has_direct_hd_url(self) -> None:
        fields = facebook_post.parse_post_html(_page({"data": {"node_v2": VIDEO_STORY}}), "https://www.facebook.com/attn/posts/pfbid0j1")
        self.assertEqual(fields["videos"], [{
            "video_id": "6968553779868435",
            "video_url": VIDEO_HD,
            "watch_url": "https://www.facebook.com/watch/?v=6968553779868435",
            "has_audio": True,
        }])
        self.assertEqual(fields["image_urls"], [])

    def test_reel_creation_story_not_suggested_feed(self) -> None:
        fields = facebook_post.parse_post_html(_page(REEL_BLOCK), "https://www.facebook.com/reel/1195289147628387")
        self.assertEqual(fields["text"], "Reel caption")
        self.assertEqual(fields["author"], "Beast Camp")
        self.assertEqual([video["video_id"] for video in fields["videos"]], ["1195289147628387"])

    def test_story_matching_url_id_wins(self) -> None:
        other = {**VIDEO_STORY, "post_id": "111111111"}
        page = _page({"data": {"node": other}}, {"data": {"node_v2": ALBUM_STORY}})
        fields = facebook_post.parse_post_html(page, GROUP_POST)
        self.assertEqual(fields["author"], "Luo")


def _fetcher(final_url: str, status: int, page: str):
    def fetch(url, *, timeout_seconds=30):
        return final_url, status, page
    return fetch


class FetchFacebookPostTests(unittest.TestCase):
    def test_share_link_payload(self) -> None:
        page = _page({"data": {"node_v2": ALBUM_STORY}})
        post = facebook_post.fetch_facebook_post(SHARE_URL, fetch=_fetcher(GROUP_POST, 200, page))
        self.assertEqual(post["platform"], "facebook")
        self.assertEqual(post["post_url"], "https://www.facebook.com/groups/hikers/permalink/4726654250936935/")
        self.assertEqual(post["title"], "Luo in Hikers")
        self.assertEqual(post["media_urls"], [PHOTO_1, PHOTO_2])
        self.assertEqual(post["videos"], [])
        # The same post shared through different links gets the same note id.
        again = facebook_post.fetch_facebook_post(GROUP_POST, fetch=_fetcher(GROUP_POST, 200, page))
        self.assertEqual(post["guid"], again["guid"])

    def test_video_payload(self) -> None:
        url = "https://www.facebook.com/attn/posts/pfbid0j1"
        post = facebook_post.fetch_facebook_post(url, fetch=_fetcher(url, 200, _page({"data": {"node_v2": VIDEO_STORY}})))
        self.assertEqual(post["videos"], [{"post_url": "https://www.facebook.com/watch/?v=6968553779868435", "video_url": VIDEO_HD}])

    def test_muted_video_is_skipped(self) -> None:
        story = json.loads(json.dumps(VIDEO_STORY))
        story["attachments"][0]["styles"]["attachment"]["media"]["audio_availability"] = "UNAVAILABLE"
        url = "https://www.facebook.com/attn/posts/pfbid0j1"
        post = facebook_post.fetch_facebook_post(url, fetch=_fetcher(url, 200, _page({"data": {"node_v2": story}})))
        self.assertEqual(post["videos"], [])

    def test_login_wall_and_empty_shell(self) -> None:
        with self.assertRaisesRegex(facebook_post.FacebookPostError, "signed-in"):
            facebook_post.fetch_facebook_post(
                SHARE_URL, fetch=_fetcher("https://www.facebook.com/login/?next=x", 200, "")
            )
        with self.assertRaisesRegex(facebook_post.FacebookPostError, "signed-in"):
            facebook_post.fetch_facebook_post(
                SHARE_URL, fetch=_fetcher(GROUP_POST, 200, "<html><title>Facebook</title></html>")
            )

    def test_not_a_post(self) -> None:
        with self.assertRaises(facebook_post.FacebookPostError):
            facebook_post.fetch_facebook_post("https://www.facebook.com/dougpuob")

    def test_load_public_post_uses_facebook_reader(self) -> None:
        sentinel = {"kind": "post", "platform": "facebook"}
        with patch.object(webui.facebook_post, "fetch_facebook_post", return_value=sentinel) as reader:
            self.assertIs(webui._load_public_post(SHARE_URL), sentinel)
        reader.assert_called_once_with(SHARE_URL)
        with patch.object(
            webui.facebook_post, "fetch_facebook_post", side_effect=facebook_post.FacebookPostError("nope")
        ):
            with self.assertRaisesRegex(ValueError, "nope"):
                webui._load_public_post(SHARE_URL)


class RunFacebookPostTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        clip_requests.configure(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_photos_to_immich_and_videos_transcribed(self) -> None:
        payload = {
            "url": SHARE_URL,
            "post_url": CANONICAL,
            "title": "Luo in Hikers",
            "text": "post",
            "markdown": f"post\n\n![]({PHOTO_1})",
            "media_urls": [PHOTO_1],
            "videos": [
                {"post_url": "https://www.facebook.com/watch/?v=1", "video_url": VIDEO_HD},
                {"post_url": "https://www.facebook.com/watch/?v=2", "video_url": ""},
            ],
        }
        uploaded: list[list[str]] = []
        calls: list[tuple[str, str]] = []

        def store(image_urls, **_kwargs):
            uploaded.append(list(image_urls))
            return {"images": [{"url": u, "embedded_url": "https://immich.example/x.jpg"} for u in image_urls], "share_url": ""}

        created = clip_requests.create(kind="post", source=SHARE_URL)
        with patch.object(clip_pipeline.web_article, "store_note_media", side_effect=store):
            clip_pipeline.run_post(
                created["id"],
                SHARE_URL,
                settings=lambda: SETTINGS,
                chat=lambda _s, _u, step: "潤稿" if step == "polish" else "標題",
                collect_threads=lambda _url: self.fail("not Threads"),
                fetch_public_post=lambda _url: payload,
                transcribe_video=lambda post_url, video_url: calls.append((post_url, video_url)) or f"逐字稿 {post_url[-1]}",
            )
        stored = clip_requests.get(created["id"])
        self.assertEqual(stored["status"], "completed")
        self.assertEqual(uploaded, [[PHOTO_1]])
        self.assertEqual(calls, [
            ("https://www.facebook.com/watch/?v=1", VIDEO_HD),
            ("https://www.facebook.com/watch/?v=2", ""),
        ])
        self.assertIn("## Video Transcript", stored["content"])
        self.assertIn("逐字稿 2", stored["content"])
        self.assertIn(CANONICAL, stored["sources"])


class TranscribeFacebookVideoTests(unittest.TestCase):
    WATCH = "https://www.facebook.com/watch/?v=6968553779868435"

    def test_direct_download_uses_facebook_referer(self) -> None:
        seen: dict = {}

        def direct(_url, destination, _max, **kwargs):
            seen.update(kwargs)
            with open(destination, "wb") as output:
                output.write(b"x")
            return destination

        with (
            patch.object(webui, "_download_post_video_direct", side_effect=direct),
            patch.object(webui.transcriber, "transcribe", return_value={"text": "hi"}),
            patch.object(webui, "_settings_transcribe_options", return_value={}),
        ):
            self.assertEqual(webui._transcribe_post_video(self.WATCH, VIDEO_HD), "hi")
        self.assertEqual(seen["referer"], "https://www.facebook.com/")

    def test_missing_or_expired_link_falls_back_to_yt_dlp(self) -> None:
        def page(url, destination, _max, _progress):
            with open(destination, "wb") as output:
                output.write(b"x")
            return {"downloaded_path": destination}

        for video_url in ("", VIDEO_HD):
            with (
                patch.object(webui, "_download_post_video_direct", side_effect=RuntimeError("HTTP 403")),
                patch.object(webui, "_download_media_page", side_effect=page) as media_page,
                patch.object(webui.transcriber, "transcribe", return_value={"text": "yt"}),
                patch.object(webui, "_settings_transcribe_options", return_value={}),
            ):
                self.assertEqual(webui._transcribe_post_video(self.WATCH, video_url), "yt")
            self.assertEqual(media_page.call_args.args[0], self.WATCH)


if __name__ == "__main__":
    unittest.main()
