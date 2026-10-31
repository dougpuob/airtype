import unittest

from app.config_schema import normalize_app_settings, thinking_budget_for_level


class ThinkingLevelTests(unittest.TestCase):
    def test_tags_default_is_mid(self) -> None:
        settings = normalize_app_settings({})
        self.assertEqual(settings["capture_post"]["tags_thinking_level"], "mid")

    def test_level_is_kept_independent_of_thinking_steps(self) -> None:
        settings = normalize_app_settings(
            {"capture_post": {"thinking_steps": ["title", "tags"], "tags_thinking_level": "off"}}
        )
        self.assertEqual(settings["capture_post"]["tags_thinking_level"], "off")
        self.assertEqual(settings["capture_post"]["thinking_steps"], ["title", "tags"])

    def test_unknown_level_falls_back_and_aliases_work(self) -> None:
        self.assertEqual(normalize_app_settings({"capture_post": {"tags_thinking_level": "x"}})["capture_post"]["tags_thinking_level"], "mid")
        self.assertEqual(normalize_app_settings({"capture_post": {"tags_thinking_level": "高"}})["capture_post"]["tags_thinking_level"], "high")

    def test_budgets(self) -> None:
        self.assertIsNone(thinking_budget_for_level("off"))
        self.assertEqual(thinking_budget_for_level("low"), 256)
        self.assertEqual(thinking_budget_for_level("mid"), 512)
        self.assertEqual(thinking_budget_for_level("high"), 1024)


class StripThinkingTests(unittest.TestCase):
    def test_keeps_text_after_last_close_tag(self) -> None:
        from app.main import _strip_thinking_blocks

        self.assertEqual(_strip_thinking_blocks("reasoning leak</think>\n#a #b"), "#a #b")
        self.assertEqual(_strip_thinking_blocks("<think>x</think> y </think>#tag"), "#tag")
        self.assertEqual(_strip_thinking_blocks("#plain"), "#plain")


if __name__ == "__main__":
    unittest.main()
