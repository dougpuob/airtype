"""Log redaction for Obsidian export tokens and auth headers."""

import unittest

from app.service_log import redact_log_text


class ServiceLogRedactionTests(unittest.TestCase):
    def test_redacts_query_token_and_authorization_headers(self) -> None:
        line = (
            '127.0.0.1:1 - "POST /api/obsidian-exports/abc/complete'
            '?token=super-secret-token&x=1 HTTP/1.1" 200'
        )
        redacted = redact_log_text(line)
        self.assertNotIn("super-secret-token", redacted)
        self.assertIn("token=[redacted]", redacted)
        self.assertIn("x=1", redacted)
        self.assertNotIn("dXNlcjpwYXNz", redact_log_text("Authorization: Basic dXNlcjpwYXNz"))
        self.assertNotIn("bearer-secret", redact_log_text("authorization: Bearer bearer-secret"))

    def test_leaves_unrelated_token_keys(self) -> None:
        self.assertEqual(redact_log_text("max_tokens=32"), "max_tokens=32")
        self.assertEqual(redact_log_text("export_id=20261108-abc saved=2"), "export_id=20261108-abc saved=2")


if __name__ == "__main__":
    unittest.main()
