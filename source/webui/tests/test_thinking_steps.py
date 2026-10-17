import unittest

from app.config_schema import normalize_app_settings, thinking_enabled_for_step


class ThinkingStepTests(unittest.TestCase):
    def test_title_thinking_is_the_default(self) -> None:
        settings = normalize_app_settings({"capture_post": {"ai_title_enabled": True}})
        self.assertEqual(settings["capture_post"]["thinking_steps"], ["title"])
        self.assertTrue(thinking_enabled_for_step("title", settings["capture_post"]["thinking_steps"]))
        self.assertFalse(thinking_enabled_for_step("polish", settings["capture_post"]["thinking_steps"]))
        self.assertFalse(thinking_enabled_for_step("tags", settings["capture_post"]["thinking_steps"]))

    def test_empty_list_turns_every_step_off(self) -> None:
        settings = normalize_app_settings({"capture_post": {"thinking_steps": []}})
        self.assertEqual(settings["capture_post"]["thinking_steps"], [])

    def test_unknown_steps_are_dropped_and_order_is_stable(self) -> None:
        settings = normalize_app_settings(
            {"capture_post": {"thinking-steps": ["tags", "title", "title", "summary"]}}
        )
        self.assertEqual(settings["capture_post"]["thinking_steps"], ["tags", "title"])


if __name__ == "__main__":
    unittest.main()
