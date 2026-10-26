import unittest

from app import clip_pipeline as cp


class EpisodeLabelTests(unittest.TestCase):
    def test_finds_common_markers(self) -> None:
        self.assertEqual(cp.episode_label("EP707 | 🦋"), "EP707")
        self.assertEqual(cp.episode_label("節目 第12集：開場"), "第12集")
        self.assertEqual(cp.episode_label("Show S2E3 title"), "S2E3")
        self.assertEqual(cp.episode_label("Talk #45"), "#45")
        self.assertEqual(cp.episode_label("No number here"), "")
        self.assertEqual(cp.episode_label("Deep dive into STEP1000"), "")

    def test_prefixes_missing_label(self) -> None:
        self.assertEqual(cp.with_episode_label("這什麼鬼成長", "EP707 | 🦋"), "EP707 這什麼鬼成長")

    def test_keeps_title_that_already_has_label(self) -> None:
        self.assertEqual(cp.with_episode_label("EP707 這什麼鬼成長", "EP707 | 🦋"), "EP707 這什麼鬼成長")

    def test_no_label_leaves_title(self) -> None:
        self.assertEqual(cp.with_episode_label("一般標題", "Some show"), "一般標題")


if __name__ == "__main__":
    unittest.main()
