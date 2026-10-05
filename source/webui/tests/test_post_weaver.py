"""Regression tests for Post Weaver."""

import json
from pathlib import Path
import tempfile
import unittest
import uuid

from app.note_id import note_guid_for_source
from app.post_weaver import (
    ThreadsChainCollector,
    ThreadsPost,
    WARNING_INCOMPLETE,
    WARNING_NOT_OP_CHAIN,
    WARNING_UNCONFIRMED_OP,
    _cookies_header_for_url,
    posts_to_markdown,
)


CASE_PATH = Path(__file__).with_name("fixtures") / "test_post_weaver_test01_data.json"


def _page(payload: dict) -> str:
    return f'<script type="application/json" data-sjs>{json.dumps(payload, ensure_ascii=False)}</script>'


def _item(
    code: str,
    author: str,
    text: str,
    *,
    is_reply: bool | None = None,
    reply_to: str | None = None,
    parent_code: str | None = None,
    taken_at: int | None = None,
    reply_count: int | None = None,
    replies: list | None = None,
) -> dict:
    post: dict = {
        "pk": code,
        "code": code,
        "user": {"username": author},
        "caption": {"text": text},
    }
    if taken_at is not None:
        post["taken_at"] = taken_at
    info: dict = {}
    if is_reply is not None:
        info["is_reply"] = is_reply
    if reply_to is not None:
        info["reply_to_author"] = {"username": reply_to}
    if parent_code is not None:
        info["parent_post"] = {"code": parent_code}
    if reply_count is not None:
        info["direct_reply_count"] = reply_count
    if info:
        post["text_post_app_info"] = info
    item: dict = {"post": post}
    if replies:
        item["replies"] = {"thread_items": replies}
    return item


class RecordingCollector(ThreadsChainCollector):
    def __init__(self, pages: dict[str, str], **kwargs) -> None:
        super().__init__(**kwargs)
        self.pages = pages
        self.fetched: list[str] = []

    def _fetch(self, url: str) -> str:
        self.fetched.append(url)
        page = self.pages.get(url)
        if page is None:
            raise RuntimeError(f"missing fixture page: {url}")
        return page


class ThreadsPostWeaverTests(unittest.TestCase):
    def test_largitdata_post(self) -> None:
        case = json.loads(CASE_PATH.read_text())

        output = ThreadsChainCollector().collect_page(
            case["input_url"],
            case["page"],
        )

        self.assertEqual(len(output["posts"]), case["expected_post_count"])
        self.assertEqual(
            [post["text"] for post in output["posts"]],
            case["expected_post_texts"],
        )
        self.assertEqual(output["warnings"], [])
        self.assertEqual(output["kind"], "post")
        self.assertEqual(output["markdown"], posts_to_markdown(output["posts"]))
        self.assertIn(case["expected_post_texts"][0], output["markdown"])
        self.assertEqual(output["guid"], note_guid_for_source(case["input_url"]))
        self.assertEqual(uuid.UUID(output["guid"]).version, 5)

    def test_posts_to_markdown_embeds_images_and_drops_duplicates(self) -> None:
        markdown = posts_to_markdown(
            [
                ThreadsPost(
                    "p1",
                    "https://www.threads.com/@alice/post/p1",
                    "alice",
                    "第一則",
                    ("https://cdn.example/a.jpg",),
                ),
                {"text": "第二則", "media_urls": ["https://cdn.example/b.jpg", ""]},
                {"text": "第一則", "media_urls": ["https://cdn.example/a.jpg"]},
                {"text": "   ", "media_urls": []},
            ]
        )
        self.assertEqual(
            markdown,
            "第一則\n\n![](https://cdn.example/a.jpg)\n\n第二則\n\n![](https://cdn.example/b.jpg)",
        )

    def test_media_and_self_thread_payload_format_collects_spine(self) -> None:
        """The current Threads payload puts posts under ``data.media`` and
        ``text_post_app_info.self_thread.posts.edges`` instead of the classic
        ``thread_items`` lists."""
        reply_leaf = {
            "pk": "p2",
            "code": "p2",
            "user": {"username": "alice"},
            "caption": {"text": "2/2 continued"},
            "text_post_app_info": {
                "is_reply": True,
                "reply_to_author": {"username": "alice"},
            },
        }
        reply_media = {
            **reply_leaf,
            "text_post_app_info": {
                **reply_leaf["text_post_app_info"],
                "self_thread": {"posts": {"edges": [{"node": reply_leaf}]}},
            },
        }
        op = {
            "pk": "op",
            "code": "op",
            "user": {"username": "alice"},
            "caption": {"text": "1/2 start"},
            "text_post_app_info": {"self_thread": {}},
        }
        page = _page(
            {
                "require": [
                    [
                        "ScheduledServerJS",
                        "handle",
                        None,
                        [
                            {
                                "__bbox": {
                                    "require": [
                                        [
                                            "RelayPrefetchedStreamCache",
                                            "next",
                                            None,
                                            [
                                                "adp_BarcelonaPostPageQuery",
                                                {
                                                    "__bbox": {
                                                        "result": {"data": {"media": op}}
                                                    }
                                                },
                                            ],
                                        ]
                                    ]
                                }
                            }
                        ],
                    ]
                ],
                "spine": {"require": [{"__bbox": {"result": {"data": {"media": reply_media}}}}]},
            }
        )

        output = ThreadsChainCollector().collect_page(
            "https://www.threads.com/@alice/post/op",
            page,
        )

        self.assertEqual(
            [post["text"] for post in output["posts"]],
            ["1/2 start", "2/2 continued"],
        )
        self.assertEqual(output["warnings"], [])

    def test_threads_share_url_resolves_before_fetching(self) -> None:
        case = json.loads(CASE_PATH.read_text())

        class ShareCollector(ThreadsChainCollector):
            def __init__(self) -> None:
                super().__init__()
                self.fetched: list[str] = []

            def _resolve_share_url(self, url: str) -> str:
                return case["input_url"]

            def _fetch(self, url: str) -> str:
                self.fetched.append(url)
                return case["page"]

        collector = ShareCollector()
        output = collector.collect("https://www.threads.com/share/HjFW63xVh/")

        self.assertEqual(
            collector.fetched[0],
            "https://www.threads.com/@largitdata/post/DZ7jXhqj-rV",
        )
        self.assertEqual(len(output["posts"]), case["expected_post_count"])

    def test_cookies_header_reads_threads_cookies(self) -> None:
        cookie_text = "\n".join(
            [
                "# Netscape HTTP Cookie File",
                ".threads.com\tTRUE\t/\tTRUE\t1893456000\tsessionid\tabc123",
                "#HttpOnly_.threads.com\tTRUE\t/\tTRUE\t1893456000\tcsrftoken\tcsrf456",
                ".example.com\tTRUE\t/\tTRUE\t1893456000\tignored\tnope",
            ]
        )
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as cookie_file:
            cookie_file.write(cookie_text)
            cookie_file.flush()

            header = _cookies_header_for_url(
                cookie_file.name,
                "https://www.threads.com/@largitdata/post/DZ7jXhqj-rV",
            )

        self.assertEqual(header, "sessionid=abc123; csrftoken=csrf456")

    def test_self_replies_in_adjacent_payload_groups_are_joined(self) -> None:
        page = _page(
            {
                "conversation": {"thread_items": [_item("op", "alice", "part 1", is_reply=False)]},
                "continuation": {
                    "thread_items": [_item("p2", "alice", "part 2", is_reply=True, reply_to="alice")]
                },
                "recommendation": {
                    "thread_items": [_item("zzz", "alice", "unrelated", is_reply=False)]
                },
            }
        )
        output = ThreadsChainCollector().collect_page(
            "https://www.threads.com/@alice/post/op",
            page,
        )
        self.assertEqual([post["text"] for post in output["posts"]], ["part 1", "part 2"])
        self.assertEqual(output["warnings"], [])

    def test_op_group_plus_self_reply_group_collects_the_whole_spine(self) -> None:
        """Threads often splits a numbered essay into the OP group plus one reply group."""
        replies = [
            _item(f"p{index}", "alice", f"{index}/12 continued", is_reply=True, reply_to="alice")
            for index in range(2, 13)
        ]
        page = _page(
            {
                "thread": {"thread_items": [_item("op", "alice", "1/12 start", is_reply=False)]},
                "replies": {"thread_items": replies},
            }
        )
        output = ThreadsChainCollector().collect_page(
            "https://www.threads.com/@alice/post/op",
            page,
        )
        self.assertEqual(len(output["posts"]), 12)
        self.assertEqual(output["posts"][0]["text"], "1/12 start")
        self.assertEqual(output["posts"][-1]["text"], "12/12 continued")
        self.assertEqual(output["warnings"], [])

    def test_share_url_resolves_then_collects_the_whole_spine(self) -> None:
        replies = [
            _item(f"p{index}", "alice", f"{index}/12 continued", is_reply=True, reply_to="alice")
            for index in range(2, 13)
        ]
        page = _page(
            {
                "thread": {"thread_items": [_item("op", "alice", "1/12 start", is_reply=False)]},
                "replies": {"thread_items": replies},
            }
        )
        post_url = "https://www.threads.com/@alice/post/op"

        class ShareCollector(ThreadsChainCollector):
            def _resolve_share_url(self, url: str) -> str:
                return post_url

            def _fetch(self, url: str) -> str:
                return page

        output = ShareCollector().collect("https://www.threads.com/share/GAxIncHkq/")
        self.assertEqual(len(output["posts"]), 12)
        self.assertEqual(output["posts"][0]["text"], "1/12 start")

    def test_caption_keeps_paragraph_breaks(self) -> None:
        page = _page(
            {
                "thread_items": [
                    _item("op", "alice", "標題\n1/12第一段\n\n第二段", is_reply=False),
                ]
            }
        )
        output = ThreadsChainCollector().collect_page(
            "https://www.threads.com/@alice/post/op",
            page,
        )
        self.assertEqual(output["posts"][0]["text"], "標題\n1/12第一段\n\n第二段")

    def test_self_replies_in_a_later_data_sjs_payload_are_collected(self) -> None:
        """Logged-in Threads pages often put the OP in one script and the spine in another."""
        replies = [
            _item(f"p{index}", "alice", f"{index}/12 continued", is_reply=True, reply_to="alice")
            for index in range(2, 13)
        ]
        page = _page({"thread_items": [_item("op", "alice", "1/12 start", is_reply=False)]}) + _page(
            {"thread_items": replies}
        )
        output = ThreadsChainCollector().collect_page(
            "https://www.threads.com/@alice/post/op",
            page,
        )
        self.assertEqual(len(output["posts"]), 12)
        self.assertEqual(output["posts"][0]["text"], "1/12 start")
        self.assertEqual(output["posts"][-1]["text"], "12/12 continued")
        self.assertEqual(output["warnings"], [])

    def test_later_payload_recommendations_are_not_absorbed(self) -> None:
        page = _page({"thread_items": [_item("op", "alice", "essay", is_reply=False)]}) + _page(
            {"thread_items": [_item("zzz", "alice", "unrelated profile post", is_reply=False)]}
        )
        output = ThreadsChainCollector().collect_page(
            "https://www.threads.com/@alice/post/op",
            page,
        )
        self.assertEqual([post["text"] for post in output["posts"]], ["essay"])

    def test_same_author_unmarked_posts_in_conversation_are_kept(self) -> None:
        page = _page(
            {
                "thread_items": [
                    _item("aaa", "alice", "part 1"),
                    _item("bbb", "alice", "part 2"),
                    _item("ccc", "alice", "part 3"),
                ],
                "recommendation": {
                    "thread_items": [_item("zzz", "alice", "unrelated profile post", is_reply=False)]
                },
            }
        )
        output = ThreadsChainCollector().collect_page(
            "https://www.threads.com/@alice/post/aaa",
            page,
        )
        self.assertEqual([post["text"] for post in output["posts"]], ["part 1", "part 2", "part 3"])
        self.assertEqual(output["warnings"], [])

    def test_author_replies_to_others_are_excluded(self) -> None:
        page = _page(
            {
                "thread_items": [
                    _item("op", "alice", "essay"),
                    _item("self1", "alice", "continued", is_reply=True, reply_to="alice"),
                    _item("comment", "bob", "nice post", is_reply=True, reply_to="alice"),
                    _item("to_bob", "alice", "thanks bob", is_reply=True, reply_to="bob"),
                    _item("self2", "alice", "still the essay", is_reply=True, reply_to="alice"),
                ]
            }
        )
        output = ThreadsChainCollector().collect_page(
            "https://www.threads.com/@alice/post/self1",
            page,
        )
        self.assertEqual(
            [post["text"] for post in output["posts"]],
            ["essay", "continued", "still the essay"],
        )
        self.assertEqual(output["warnings"], [])

    def test_reply_to_other_author_imports_only_the_pasted_post(self) -> None:
        page = _page(
            {
                "thread_items": [
                    _item("op", "bob", "bob's post"),
                    _item("r1", "alice", "alice replies", is_reply=True, reply_to="bob"),
                    _item("r2", "alice", "alice continues", is_reply=True, reply_to="alice"),
                ]
            }
        )
        output = ThreadsChainCollector().collect_page(
            "https://www.threads.com/@alice/post/r1",
            page,
        )
        self.assertEqual([post["text"] for post in output["posts"]], ["alice replies"])
        self.assertEqual(output["warnings"], [WARNING_NOT_OP_CHAIN])

    def test_self_reply_in_someone_elses_thread_is_not_a_chain(self) -> None:
        page = _page(
            {
                "thread_items": [
                    _item("op", "bob", "bob's post"),
                    _item("r1", "alice", "alice replies", is_reply=True, reply_to="bob"),
                    _item("r2", "alice", "alice continues", is_reply=True, reply_to="alice"),
                ]
            }
        )
        output = ThreadsChainCollector().collect_page(
            "https://www.threads.com/@alice/post/r2",
            page,
        )
        self.assertEqual([post["text"] for post in output["posts"]], ["alice continues"])
        self.assertEqual(output["warnings"], [WARNING_NOT_OP_CHAIN])

    def test_nested_self_replies_are_collected(self) -> None:
        page = _page(
            {
                "thread_items": [
                    _item(
                        "op",
                        "alice",
                        "part 1",
                        replies=[
                            _item("p2", "alice", "part 2", is_reply=True, reply_to="alice"),
                            _item("p3", "alice", "part 3", is_reply=True, reply_to="alice"),
                        ],
                    )
                ]
            }
        )
        output = ThreadsChainCollector().collect_page(
            "https://www.threads.com/@alice/post/op",
            page,
        )
        self.assertEqual([post["text"] for post in output["posts"]], ["part 1", "part 2", "part 3"])

    def test_unconfirmed_op_keeps_visible_continuation(self) -> None:
        page = _page(
            {
                "thread_items": [
                    _item("p2", "alice", "part 2", is_reply=True, reply_to="alice"),
                    _item("p3", "alice", "part 3", is_reply=True, reply_to="alice"),
                ]
            }
        )
        output = ThreadsChainCollector().collect_page(
            "https://www.threads.com/@alice/post/p2",
            page,
        )
        self.assertEqual([post["text"] for post in output["posts"]], ["part 2", "part 3"])
        self.assertEqual(output["warnings"], [WARNING_UNCONFIRMED_OP])

    def test_collect_expands_parent_and_later_continuation_pages(self) -> None:
        op_url = "https://www.threads.com/@alice/post/op"
        mid_url = "https://www.threads.com/@alice/post/p2"
        last_url = "https://www.threads.com/@alice/post/p3"
        pages = {
            mid_url: _page(
                {
                    "thread_items": [
                        _item("p2", "alice", "part 2", is_reply=True, reply_to="alice", parent_code="op"),
                    ]
                }
            ),
            op_url: _page(
                {
                    "thread_items": [
                        _item("op", "alice", "part 1", is_reply=False),
                        _item("p2", "alice", "part 2", is_reply=True, reply_to="alice"),
                        _item("p3", "alice", "part 3", is_reply=True, reply_to="alice"),
                    ]
                }
            ),
            last_url: _page(
                {
                    "thread_items": [
                        _item("p3", "alice", "part 3", is_reply=True, reply_to="alice"),
                    ]
                }
            ),
        }
        collector = RecordingCollector(pages)
        output = collector.collect(mid_url)
        self.assertEqual([post["text"] for post in output["posts"]], ["part 1", "part 2", "part 3"])
        self.assertEqual(output["warnings"], [])
        self.assertIn(op_url, collector.fetched)
        self.assertIn(mid_url, collector.fetched)

    def test_expansion_failure_keeps_visible_posts_and_warns(self) -> None:
        mid_url = "https://www.threads.com/@alice/post/p2"
        pages = {
            mid_url: _page(
                {
                    "thread_items": [
                        _item("p2", "alice", "part 2", is_reply=True, reply_to="alice", parent_code="op"),
                        _item("p3", "alice", "part 3", is_reply=True, reply_to="alice"),
                    ]
                }
            )
        }
        collector = RecordingCollector(pages)
        output = collector.collect(mid_url)
        self.assertEqual([post["text"] for post in output["posts"]], ["part 2", "part 3"])
        self.assertIn(WARNING_UNCONFIRMED_OP, output["warnings"])

    def test_max_posts_truncates_and_warns_incomplete(self) -> None:
        page = _page(
            {
                "thread_items": [
                    _item("p1", "alice", "one", is_reply=False),
                    _item("p2", "alice", "two", is_reply=True, reply_to="alice"),
                    _item("p3", "alice", "three", is_reply=True, reply_to="alice"),
                ]
            }
        )
        output = ThreadsChainCollector(max_posts=2).collect_page(
            "https://www.threads.com/@alice/post/p1",
            page,
        )
        self.assertEqual([post["text"] for post in output["posts"]], ["one", "two"])
        self.assertEqual(output["warnings"], [WARNING_INCOMPLETE])

    def test_logged_in_cookies_do_not_hide_a_public_continuation_spine(self) -> None:
        op_only = _page(
            {
                "thread_items": [
                    _item("op", "alice", "1/12 start", is_reply=False, reply_count=11),
                ]
            }
        )
        full = _page(
            {
                "thread": {"thread_items": [_item("op", "alice", "1/12 start", is_reply=False, reply_count=11)]},
                "replies": {
                    "thread_items": [
                        _item(f"p{index}", "alice", f"{index}/12 continued", is_reply=True, reply_to="alice")
                        for index in range(2, 13)
                    ]
                },
            }
        )
        post_url = "https://www.threads.com/@alice/post/op"

        class CookiePoisonedCollector(ThreadsChainCollector):
            def _fetch(self, url: str) -> str:
                return op_only if getattr(self, "_fetch_use_cookies", True) else full

        output = CookiePoisonedCollector(cookie_header="sessionid=fake").collect(post_url)
        self.assertEqual(len(output["posts"]), 12)
        self.assertEqual(output["fetch"], "anonymous")
        self.assertEqual(output["posts"][-1]["text"], "12/12 continued")

    def test_browser_session_is_used_when_html_omits_self_replies(self) -> None:
        op_only = _page(
            {
                "thread_items": [
                    _item("op", "alice", "1/12 start", is_reply=False, reply_count=11),
                ]
            }
        )
        full = _page(
            {
                "thread": {"thread_items": [_item("op", "alice", "1/12 start", is_reply=False, reply_count=11)]},
                "replies": {
                    "thread_items": [
                        _item(f"p{index}", "alice", f"{index}/12 continued", is_reply=True, reply_to="alice")
                        for index in range(2, 13)
                    ]
                },
            }
        )
        post_url = "https://www.threads.com/@alice/post/op"
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as state_file:
            state_file.write("{}")
            state_file.flush()

            class BrowserCollector(ThreadsChainCollector):
                def _fetch(self, url: str) -> str:
                    return op_only

                def _fetch_with_browser(self, url: str) -> str:
                    return full

            output = BrowserCollector(
                cookie_header="sessionid=fake",
                storage_state_path=state_file.name,
            ).collect(post_url)

        self.assertEqual(len(output["posts"]), 12)
        self.assertEqual(output["fetch"], "browser")

    def test_truncated_public_page_warns_incomplete_without_auth(self) -> None:
        op_only = _page(
            {
                "thread_items": [
                    _item("op", "alice", "1/12 start", is_reply=False, reply_count=11),
                ]
            }
        )

        class TruncatedCollector(ThreadsChainCollector):
            def _fetch(self, url: str) -> str:
                return op_only

        output = TruncatedCollector().collect("https://www.threads.com/@alice/post/op")
        self.assertEqual(len(output["posts"]), 1)
        self.assertEqual(output["posts"][0]["text"], "1/12 start")
        self.assertEqual(output["warnings"], [WARNING_INCOMPLETE])


if __name__ == "__main__":
    unittest.main()
