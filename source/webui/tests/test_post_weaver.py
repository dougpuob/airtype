"""Regression tests for Post Weaver."""

import json
from pathlib import Path
import unittest

from app.post_weaver import ThreadsChainCollector


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

if __name__ == "__main__":
    unittest.main()
