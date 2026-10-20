import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

from app import threads_watch as tw


def _post(code, ts, user="n.ina3373", text="第一行\n第二行", images=0, video=False):
    post = {"code": code, "taken_at": ts, "user": {"username": user}, "caption": {"text": text}}
    if images > 1:
        post["carousel_media"] = [{"image_versions2": {"candidates": [{"url": f"https://x/{i}.jpg"}]}} for i in range(images)]
    elif images == 1:
        post["image_versions2"] = {"candidates": [{"url": "https://x/a.jpg"}]}
    if video:
        post["video_versions"] = [{"url": "https://x/v.mp4"}]
    return post


def _page(*groups):
    payload = {"data": {"edges": [{"node": {"thread_items": [{"post": p} for p in group]}} for group in groups]}}
    return f'<script type="application/json" data-sjs>{json.dumps(payload)}</script> "username":"n.ina3373"'


class NormalizeTests(unittest.TestCase):
    def test_accepts_names_and_urls(self):
        cases = {
            "n.ina3373": "n.ina3373",
            "@N.ina3373": "n.ina3373",
            "  @n.ina3373 ": "n.ina3373",
            "https://www.threads.com/@n.ina3373?igshid=NTc4MTIwNjQ2YQ==": "n.ina3373",
            "https://threads.net/@n.ina3373/post/DeizpylAcxa": "n.ina3373",
            "www.threads.com/@some_user.x": "some_user.x",
            "http://www.threads.com/%40n.ina3373/": "n.ina3373",
        }
        for raw, expected in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(tw.normalize_threads_username(raw), expected)

    def test_rejects_bad_input(self):
        for raw in ["", "https://www.instagram.com/@x", "https://www.threads.com/search", "has space", "a/b"]:
            with self.subTest(raw=raw):
                with self.assertRaises(ValueError):
                    tw.normalize_threads_username(raw)

    def test_interval_is_clamped(self):
        self.assertEqual(tw.clamp_interval(5), tw.MIN_INTERVAL_MINUTES)
        self.assertEqual(tw.clamp_interval("abc"), tw.DEFAULT_INTERVAL_MINUTES)
        self.assertEqual(tw.clamp_interval(90), 90)


class ParseTests(unittest.TestCase):
    def test_profile_page_keeps_owner_thread_heads(self):
        page = _page(
            [_post("A1", 200, images=3), _post("A1reply", 201)],  # self-thread: only head counts
            [_post("B2", 300, video=True)],
            [_post("C3", 400, user="someone_else")],  # repost of another user
        )
        parsed = tw.parse_profile_page(page, "n.ina3373")
        self.assertEqual([p["code"] for p in parsed["posts"]], ["B2", "A1"])
        a1 = parsed["posts"][1]
        self.assertEqual((a1["image_count"], a1["video_count"], a1["title"], a1["text_length"]), (3, 0, "第一行", 7))
        self.assertEqual(parsed["posts"][0]["video_count"], 1)
        self.assertTrue(parsed["profile_seen"])

    def test_fetch_reports_login_redirect_and_falls_back_to_cookies(self):
        calls = []

        def http_get(url, cookie, timeout):
            calls.append(cookie)
            if not cookie:
                return 200, "https://www.threads.com/login?next=x", "<html></html>"
            return 200, url, _page([_post("A1", 100)])

        result = tw.fetch_profile_posts("n.ina3373", cookie_header_fn=lambda url: "sessionid=1", http_get=http_get)
        self.assertEqual(result["fetch"], "cookies")
        self.assertEqual(calls, ["", "sessionid=1"])
        with self.assertRaises(tw.WatchFetchError) as ctx:
            tw.fetch_profile_posts("n.ina3373", http_get=lambda u, c, t: (200, "https://www.threads.com/login", ""))
        self.assertEqual(ctx.exception.code, "login_wall")


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 10, 20, 5, 0, tzinfo=timezone.utc)
        self.posts = [
            {"code": c, "url": f"https://www.threads.com/@n.ina3373/post/{c}", "title": c, "post_created_at": f"2026-10-1{i}T00:00:00+08:00",
             "text_length": 10, "image_count": 0, "video_count": 0, "pinned": False}
            for i, c in enumerate(["OLD", "MID", "NEW"])
        ]
        self.queued = []

    def queue(self, url):
        self.queued.append(url)
        return {"id": f"req-{len(self.queued)}", "created_at": "2026-10-20T13:00:00+08:00"}

    def fetch(self, posts):
        return lambda username: {"fetch": "anonymous", "posts": sorted(posts, key=lambda p: p["post_created_at"], reverse=True)}

    def test_new_posts_diff_is_oldest_first(self):
        fresh = tw.find_new_posts(list(reversed(self.posts)), {"MID"})
        self.assertEqual([p["code"] for p in fresh], ["OLD", "NEW"])

    def test_first_check_is_baseline_then_only_new_posts_are_queued(self):
        target = tw.new_target("n.ina3373", now=self.now)
        tw.run_check(target, fetch_fn=self.fetch(self.posts[:2]), queue_fn=self.queue, now=self.now)
        self.assertEqual(self.queued, [])
        self.assertTrue(target["baseline_done"])
        self.assertTrue(all(p["baseline"] and p["status"] == "baseline" for p in target["posts"]))
        self.assertEqual(target["next_check_at"], (self.now + timedelta(minutes=60)).astimezone().isoformat(timespec="seconds"))

        later = self.now + timedelta(hours=1)
        tw.run_check(target, fetch_fn=self.fetch(self.posts), queue_fn=self.queue, now=later)
        self.assertEqual(self.queued, [self.posts[2]["url"]])
        entry = target["posts"][-1]
        self.assertEqual((entry["code"], entry["status"], entry["clip_request_id"], entry["baseline"]), ("NEW", "queued", "req-1", False))
        self.assertEqual(target["last_result"]["new_posts"], 1)

        tw.run_check(target, fetch_fn=self.fetch(self.posts), queue_fn=self.queue, now=later + timedelta(hours=1))
        self.assertEqual(len(self.queued), 1)  # nothing re-queued

    def test_queue_latest_option_and_dry_run(self):
        target = tw.new_target("n.ina3373", queue_latest=1, now=self.now)
        dry = tw.run_check(target, fetch_fn=self.fetch(self.posts), queue_fn=self.queue, now=self.now, queue=False)
        self.assertEqual(self.queued, [])
        self.assertEqual(dry["posts"], [])
        self.assertIsNone(dry["last_checked_at"])
        self.assertEqual(dry["_check"]["posts_found"], 3)

        tw.run_check(target, fetch_fn=self.fetch(self.posts), queue_fn=self.queue, now=self.now)
        self.assertEqual(self.queued, [self.posts[2]["url"]])
        statuses = {p["code"]: p["status"] for p in target["posts"]}
        self.assertEqual(statuses, {"OLD": "baseline", "MID": "baseline", "NEW": "queued"})

    def test_fetch_error_is_recorded(self):
        target = tw.new_target("n.ina3373", now=self.now)

        def broken(username):
            raise tw.WatchFetchError("not_found", "找不到")

        tw.run_check(target, fetch_fn=broken, queue_fn=self.queue, now=self.now)
        self.assertFalse(target["last_result"]["ok"])
        self.assertEqual(target["last_result"]["code"], "not_found")
        self.assertFalse(target["baseline_done"])

    def test_store_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = tw.WatchStore(tmp)
            target = store.save(tw.new_target("n.ina3373", now=self.now))
            self.assertEqual(store.get(target["id"])["username"], "n.ina3373")
            self.assertEqual(store.find_by_username("n.ina3373")["id"], target["id"])
            self.assertTrue(store.delete(target["id"]))
            self.assertEqual(store.list(), [])
            with self.assertRaises(ValueError):
                store.get("../etc")


if __name__ == "__main__":
    unittest.main()
