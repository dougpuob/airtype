"""Regression tests for Post Weaver."""

import json
from pathlib import Path
import tempfile
import unittest

from app.post_weaver import ThreadsChainCollector, _cookies_header_for_url


CASE_PATH = Path(__file__).with_name("fixtures") / "test_post_weaver_test01_data.json"


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

if __name__ == "__main__":
    unittest.main()
