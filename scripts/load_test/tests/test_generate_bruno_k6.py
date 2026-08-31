import tempfile
import unittest
from contextlib import redirect_stderr
from io import StringIO
from pathlib import Path

from scripts.load_test.generate_bruno_k6 import load_requests, parse_request, render_k6


class GenerateBrunoK6Test(unittest.TestCase):
    """Tests for Bruno request parsing and k6 rendering."""

    def write_bru(self, root, relative_path, content):
        """Write a Bruno fixture file under a temporary collection root."""
        path = root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content.strip() + "\n", encoding="utf-8")
        return path

    def test_load_requests_filters_external_and_destructive_requests(self):
        """Only internal non-destructive Bruno requests should be loaded by default."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_bru(
                root,
                "auth/sign-in.bru",
                """
meta {
  name: sign in
  seq: 1
}

post {
  url: {{URL}}/auth/email/sign-in
  body: json
  auth: none
}

body:json {
  {"email":"{{email}}","password":"password"}
}
""",
            )
            self.write_bru(
                root,
                "users/me.bru",
                """
meta {
  name: my info
  seq: 2
}

get {
  url: {{URL}}/my
  body: none
  auth: inherit
}

vars:pre-request {
  email: user1@example.com
}
""",
            )
            self.write_bru(
                root,
                "external/kakao.bru",
                """
get {
  url: https://kapi.kakao.com/v2/user/me
  body: none
  auth: inherit
}
""",
            )
            self.write_bru(
                root,
                "auth/quit.bru",
                """
delete {
  url: {{URL}}/auth/quit
  body: none
  auth: inherit
}
""",
            )

            requests = load_requests(root, include_external=False, include_destructive=False)

            self.assertEqual([request["url"] for request in requests], [
                "{{URL}}/auth/email/sign-in",
                "{{URL}}/my",
            ])
            self.assertEqual(requests[1]["vars"], {"email": "user1@example.com"})

    def test_render_k6_excludes_login_request_and_keeps_request_metadata(self):
        """The generated script should log in separately and retain request tags."""
        requests = [
            {
                "name": "POST /auth/email/sign-in",
                "displayName": "sign in",
                "relativePath": "auth/sign-in.bru",
                "method": "POST",
                "url": "{{URL}}/auth/email/sign-in",
                "auth": "none",
                "body": {"type": "json", "raw": "{}"},
                "vars": {},
                "seq": 1,
            },
            {
                "name": "GET /my",
                "displayName": "my info",
                "relativePath": "users/me.bru",
                "method": "GET",
                "url": "{{URL}}/my",
                "auth": "inherit",
                "body": {"type": "none"},
                "vars": {},
                "seq": 2,
            },
        ]

        script = render_k6(requests)

        self.assertIn("const requests = [", script)
        self.assertIn('"relativePath": "users/me.bru"', script)
        self.assertNotIn('"relativePath": "auth/sign-in.bru"', script)
        self.assertIn("/auth/email/sign-in", script)

    def test_parse_request_warns_for_unsupported_body_type(self):
        """Unsupported Bruno body types should be surfaced during generation."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = self.write_bru(
                root,
                "users/import.bru",
                """
post {
  url: {{URL}}/users/import
  body: formUrlEncoded
  auth: inherit
}
""",
            )

            stderr = StringIO()
            with redirect_stderr(stderr):
                request = parse_request(path, root)

            self.assertEqual(request["body"], {"type": "formUrlEncoded"})
            self.assertIn("unsupported Bruno body type", stderr.getvalue())

    def test_render_k6_skips_token_ending_requests_with_preloaded_token(self):
        """Pre-issued token mode should not send sign-out or quit requests."""
        requests = [
            {
                "name": "POST /auth/sign-out",
                "displayName": "sign out",
                "relativePath": "auth/sign-out.bru",
                "method": "POST",
                "url": "{{URL}}/auth/sign-out",
                "auth": "inherit",
                "body": {"type": "none"},
                "vars": {},
                "seq": 1,
            },
        ]

        script = render_k6(requests)

        self.assertIn("const tokenEndingPaths =", script)
        self.assertIn("preloadedAccessToken && isTokenEndingRequest(request)", script)
        self.assertIn("Skipping token-ending request", script)


if __name__ == "__main__":
    unittest.main()
