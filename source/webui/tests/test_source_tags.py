"""Deterministic note tags: short source site names, and platform / author for social posts."""

import tempfile
import unittest

from app import clip_pipeline
from app import clip_requests
from app.source_tags import domain_tags, post_identity, post_tags, tag_value


class DomainTagsTests(unittest.TestCase):
    def test_short_site_name_only(self) -> None:
        self.assertEqual(domain_tags(["https://www.kimo.com.tw/news/1"]), ["kimo"])
        self.assertEqual(domain_tags(["https://m.facebook.com/x"]), ["facebook"])
        self.assertEqual(
            domain_tags(["https://www.threads.com/@a/post/1", "https://www.threads.com/@a/post/2"]),
            ["threads"],
        )

    def test_skips_tailnet_and_non_urls(self) -> None:
        self.assertEqual(domain_tags(["https://box.tail1.ts.net/a", "file:///tmp/a.mp3", "not a url"]), [])


class PostTagsTests(unittest.TestCase):
    def test_threads(self) -> None:
        self.assertEqual(
            post_tags(["https://www.threads.com/@whaleagent/post/DfAZ_ykk4AP"]),
            ["threads", "whaleagent"],
        )

    def test_threads_handle_dots_become_hyphens(self) -> None:
        self.assertEqual(
            post_tags(["https://www.threads.net/@doug.puob/post/ABC123"]),
            ["threads", "doug-puob"],
        )

    def test_instagram_author_comes_from_payload(self) -> None:
        self.assertEqual(
            post_tags(
                ["https://www.instagram.com/p/DfFNi8dAcO6/?cplk=x", "https://www.instagram.com/p/DfFNi8dAcO6/"],
                {"author": "some.user_1"},
            ),
            ["instagram", "some-user_1"],
        )

    def test_instagram_reel_with_user_path(self) -> None:
        self.assertEqual(
            post_identity(["https://www.instagram.com/someone/reel/C0deXYZ/"]),
            {"platform": "instagram", "post_id": "C0deXYZ", "user_id": "someone"},
        )

    def test_facebook_share_link_uses_resolved_post_and_numeric_story_id(self) -> None:
        self.assertEqual(
            post_tags(
                [
                    "https://www.facebook.com/share/p/1EC8342Gce/",
                    "https://www.facebook.com/dougpuob/posts/pfbid02mDZxLuefPWiBWo",
                ],
                {"post_id": "10222852645757660", "author_id": "1022167918", "author": "Douglas Chen"},
            ),
            ["facebook", "dougpuob"],
        )

    def test_facebook_group_post_numeric_author_id_is_not_a_tag(self) -> None:
        self.assertEqual(
            post_tags(
                [
                    "https://www.facebook.com/share/p/1Cf35dUwuX/",
                    "https://www.facebook.com/groups/worriorrock/permalink/4726654250936935",
                ],
                {"post_id": "4726654250936935", "author_id": "100000366204205", "author": "Luo Shi Xuan"},
            ),
            ["facebook"],
        )

    def test_facebook_query_and_reel_urls(self) -> None:
        self.assertEqual(
            post_identity(["https://www.facebook.com/permalink.php?story_fbid=123456789&id=987654321"]),
            {"platform": "facebook", "post_id": "123456789", "user_id": "987654321"},
        )
        self.assertEqual(post_tags(["https://www.facebook.com/reel/1234567890"]), ["facebook"])

    def test_linkedin_slug_url(self) -> None:
        self.assertEqual(
            post_tags(["https://www.linkedin.com/posts/jane-doe_ai-agents-activity-7380000000000000000-AbCd"]),
            ["linkedin", "jane-doe"],
        )

    def test_linkedin_short_link_and_author_url(self) -> None:
        self.assertEqual(
            post_tags(
                ["https://lnkd.in/p/eXaMpLe", "https://www.linkedin.com/feed/update/urn:li:activity:7380000000000000001"],
                {"author_url": "https://www.linkedin.com/in/jane-doe?trk=public_post", "author": "Jane Doe"},
            ),
            ["linkedin", "jane-doe"],
        )

    def test_display_names_are_not_used_as_user_ids(self) -> None:
        self.assertEqual(
            post_tags(["https://www.threads.com/t/CODE1"], {"author": "Douglas Chen 陳"}),
            ["threads"],
        )

    def test_non_social_urls_get_no_post_tags(self) -> None:
        self.assertEqual(post_tags(["https://www.kimo.com.tw/news/1"]), [])

    def test_tag_value(self) -> None:
        self.assertEqual(tag_value("@a.b c"), "a-b-c")


class FacebookAuthorIdTests(unittest.TestCase):
    def test_actor_id_is_numeric_only(self) -> None:
        from app import facebook_post

        self.assertEqual(
            facebook_post._actor_id({"actors": [{"__typename": "User", "id": "100000366204205", "name": "Luo"}]}),
            "100000366204205",
        )
        self.assertEqual(facebook_post._actor_id({"actors": [{"name": "Luo", "id": "pfbidXYZ"}]}), "")


class DraftTagsTests(unittest.TestCase):
    def test_frontmatter_tag_order_and_ai_hashtags(self) -> None:
        draft = clip_pipeline.build_draft(
            kind="post",
            title="Hello",
            content="貼文",
            polished="",
            ai_tags="#瑞波 #Ripple\n#穩定幣 #RLUSD",
            sources=["https://www.threads.com/@whaleagent/post/DfAZ_ykk4AP"],
            guid="guid",
            share_url="",
            extra_tags=post_tags(["https://www.threads.com/@whaleagent/post/DfAZ_ykk4AP"]),
        )
        self.assertEqual(
            draft["tags"][1:],
            [
                "airtype", "capture-post", "threads",
                "whaleagent",
                "瑞波", "Ripple", "穩定幣", "RLUSD",
            ],
        )
        self.assertIn("  - whaleagent\n", draft["note"])
        self.assertFalse([tag for tag in draft["tags"] if "/" in tag or "-com" in tag or tag.isdigit()])
        self.assertNotIn("  - #", draft["note"])

    def test_article_gets_site_tags(self) -> None:
        draft = clip_pipeline.build_draft(
            kind="article", title="T", content="c", polished="", ai_tags="",
            sources=["https://tw.news.yahoo.com/a.html", "https://www.kimo.com.tw/b"], guid="g", share_url="",
        )
        self.assertEqual(draft["tags"][1:], ["airtype", "web-article", "tw", "kimo"])


class RunPostTagsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        clip_requests.configure(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_public_post_payload_ids_reach_the_note(self) -> None:
        url = "https://www.facebook.com/share/p/1Cf35dUwuX/"
        created = clip_requests.create(kind="post", source=url)
        clip_pipeline.run_post(
            created["id"],
            url,
            settings=lambda: {"web_to_markdown": {}, "immich": {}, "capture_post": {"ai_title_enabled": False}},
            chat=lambda _s, _u, step: "" if step != "tags" else "#登山 #Hiking",
            collect_threads=lambda _url: {},
            fetch_public_post=lambda _url: {
                "markdown": "鵝公髻山",
                "post_url": "https://www.facebook.com/groups/worriorrock/permalink/4726654250936935",
                "post_id": "4726654250936935",
                "author_id": "100000366204205",
                "author": "Luo Shi Xuan",
                "guid": "guid",
            },
        )
        stored = clip_requests.get(created["id"])
        assert stored is not None
        self.assertEqual(stored["status"], "completed")
        for tag in ("facebook", "登山", "Hiking"):
            self.assertIn(tag, stored["tags"])
            self.assertIn(f"  - {tag}\n", stored["note"])
        self.assertFalse([tag for tag in stored["tags"] if "/" in tag or "-com" in tag or tag.isdigit()])


if __name__ == "__main__":
    unittest.main()
