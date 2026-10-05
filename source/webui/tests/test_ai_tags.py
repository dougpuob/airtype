"""Tests for LLM hashtag normalization."""

import unittest

from app.ai_tags import build_ai_tags_prompt, normalize_ai_tags


class NormalizeAiTagsTests(unittest.TestCase):
    def test_keeps_hash_lines_and_drops_preamble(self) -> None:
        raw = "這是說明\n#柿子樹 #Persimmon\n#廣島 #Hiroshima\n1. #紀錄片 #Documentary"
        self.assertEqual(
            normalize_ai_tags(raw),
            "#柿子樹 #Persimmon\n#廣島 #Hiroshima\n#紀錄片 #Documentary",
        )

    def test_unwraps_code_fence(self) -> None:
        raw = "```\n#原子彈 #AtomicBomb\n#柿子樹 #PersimmonTree\n```"
        self.assertEqual(
            normalize_ai_tags(raw),
            "#原子彈 #AtomicBomb\n#柿子樹 #PersimmonTree",
        )

    def test_empty_without_hashes(self) -> None:
        self.assertEqual(normalize_ai_tags("沒有標籤"), "")

    def test_prompt_includes_title_and_body(self) -> None:
        prompt = build_ai_tags_prompt("文章正文", "測試標題")
        self.assertIn("標題：測試標題", prompt)
        self.assertIn("文章正文", prompt)


if __name__ == "__main__":
    unittest.main()
