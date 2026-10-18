import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PLAN_CHECK = Path(__file__).resolve().parents[1] / "plan_check.py"


def resource_change(address, actions):
    return {"address": address, "type": address.split(".")[-2], "change": {"actions": actions}}


PLAN = {
    "resource_changes": [
        resource_change("module.prod_stack.aws_instance.api_server", ["update"]),
        resource_change("aws_ebs_volume.db_data", ["delete", "create"]),
        resource_change("aws_s3_bucket.unused", ["delete"]),
        resource_change("aws_security_group.new", ["create"]),
        resource_change("aws_iam_role.same", ["no-op"]),
        resource_change("data.aws_ami.ubuntu", ["read"]),
        resource_change('module.prod_stack.mysql_user.users["secret_user"]', ["create"]),
        resource_change("aws_instance.indexed[0]", ["update"]),
    ]
}


class PlanCheckTest(unittest.TestCase):
    """Tests for plan JSON summary and intent comparison."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.plan = Path(self.tmp.name) / "plan.json"
        self.plan.write_text(json.dumps(PLAN), encoding="utf-8")

    def run_check(self, *args):
        return subprocess.run(
            [sys.executable, str(PLAN_CHECK), *args],
            capture_output=True, text=True, check=False,
        )

    def write_expect(self, content):
        path = Path(self.tmp.name) / "expect.txt"
        path.write_text(content, encoding="utf-8")
        return str(path)

    def test_summary_orders_dangerous_actions_first_and_skips_noop(self):
        result = self.run_check("summary", str(self.plan))

        self.assertEqual(result.returncode, 0)
        lines = [line.split()[1:] for line in result.stdout.splitlines()[1:]]
        self.assertEqual(lines, [
            ["delete", "aws_s3_bucket.unused"],
            ["replace", "aws_ebs_volume.db_data"],
            ["create", "aws_security_group.new"],
            ["create", 'module.prod_stack.mysql_user.users["secret_user"]'],
            ["update", "aws_instance.indexed[0]"],
            ["update", "module.prod_stack.aws_instance.api_server"],
        ])

    def test_summary_markdown_warns_on_delete_or_replace(self):
        result = self.run_check("summary", str(self.plan), "--markdown")

        self.assertIn("delete/replace", result.stdout)
        self.assertNotIn("aws_iam_role.same", result.stdout)

    def test_summary_markdown_redacts_for_each_keys_from_tfvars(self):
        result = self.run_check("summary", str(self.plan), "--markdown")

        self.assertNotIn("secret_user", result.stdout)
        self.assertIn('module.prod_stack.mysql_user.users["…"]', result.stdout)
        self.assertIn("aws_instance.indexed[0]", result.stdout)

    def test_expect_passes_when_intent_matches_with_glob(self):
        expect = self.write_expect(
            "prod update module.prod_stack.aws_instance.*\n"
            "prod replace aws_ebs_volume.db_data  # 볼륨 교체\n"
            "prod delete aws_s3_bucket.unused\n"
            "prod create aws_security_group.new\n"
            "prod create module.prod_stack.mysql_user.users[*]\n"
            "prod update aws_instance.indexed[0]\n"
            "stage delete aws_instance.other  # 다른 환경 줄은 무시\n"
        )

        result = self.run_check("expect", str(self.plan), "--env", "prod", "--expect", expect)

        self.assertEqual(result.returncode, 0, result.stdout)

    def test_expect_fails_on_unexpected_and_missing_changes(self):
        expect = self.write_expect(
            "prod update module.prod_stack.aws_instance.api_server\n"
            "prod create aws_security_group.new\n"
            "prod create aws_lb.never_planned\n"
        )

        result = self.run_check("expect", str(self.plan), "--env", "prod", "--expect", expect)

        self.assertEqual(result.returncode, 1)
        self.assertIn("의도에 없는 변경: replace aws_ebs_volume.db_data", result.stdout)
        self.assertIn("의도에 없는 변경: delete aws_s3_bucket.unused", result.stdout)
        self.assertIn("의도했으나 plan 에 없음: create aws_lb.never_planned", result.stdout)

    def test_expect_does_not_treat_replace_as_update(self):
        expect = self.write_expect("prod update aws_ebs_volume.db_data\n")

        result = self.run_check("expect", str(self.plan), "--env", "prod", "--expect", expect)

        self.assertIn("의도에 없는 변경: replace aws_ebs_volume.db_data", result.stdout)

    def test_expect_redacts_unexpected_for_each_keys_for_ci(self):
        expect = self.write_expect("")

        result = self.run_check("expect", str(self.plan), "--env", "prod", "--expect", expect, "--redact")

        self.assertNotIn("secret_user", result.stdout)
        self.assertIn('mysql_user.users["…"]', result.stdout)

    def run_extract(self, body):
        out = Path(self.tmp.name) / "extracted.txt"
        result = subprocess.run(
            [sys.executable, str(PLAN_CHECK), "extract-expect", "--out", str(out)],
            capture_output=True, text=True, check=False, env={**os.environ, "PR_BODY": body},
        )
        return result, out

    def test_extract_expect_reads_block_from_pr_body_with_crlf(self):
        body = "## 작업 내용\r\n\r\n```verify-expect\r\nprod update aws_instance.a\r\n# 주석\r\n```\r\n\r\n## 특이 사항\r\n"

        result, out = self.run_extract(body)

        self.assertEqual(result.returncode, 0)
        self.assertEqual(out.read_text(encoding="utf-8"), "prod update aws_instance.a\n# 주석\n")

    def test_extract_expect_accepts_empty_block_as_no_change(self):
        result, out = self.run_extract("```verify-expect\n```\n")

        self.assertEqual(result.returncode, 0)
        self.assertEqual(out.read_text(encoding="utf-8"), "")

    def test_extract_expect_fails_without_block(self):
        result, out = self.run_extract("```text\nprod update aws_instance.a\n```\n")

        self.assertEqual(result.returncode, 1)
        self.assertFalse(out.exists())

    def test_policy_reports_rule_error_on_stdout_as_failure(self):
        policy_dir = Path(__file__).resolve().parents[1] / "policies"
        rule = policy_dir / "zz_test_broken_rule.py"
        rule.write_text('RULE_ID = "TEST-BROKEN"\ndef check(action, change):\n    raise KeyError("x")\n', encoding="utf-8")
        self.addCleanup(rule.unlink)

        result = self.run_check("policy", str(self.plan))

        self.assertEqual(result.returncode, 1)
        self.assertIn("TEST-BROKEN", result.stdout)
        self.assertIn("규칙 실행 오류", result.stdout)

    def test_expect_rejects_malformed_line(self):
        expect = self.write_expect("prod modify aws_ebs_volume.db_data\n")

        result = self.run_check("expect", str(self.plan), "--env", "prod", "--expect", expect)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("형식 오류", result.stderr)


if __name__ == "__main__":
    unittest.main()
