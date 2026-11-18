"""Run the DB-type selection step from the Terraform Plan workflow."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github/workflows/terraform-plan.yml"


def selection_script():
    lines = WORKFLOW.read_text().splitlines()
    start = lines.index("      - name: Select DB Type for Plan")
    run = lines.index("        run: |", start)
    end = next(
        i for i in range(run + 1, len(lines))
        if lines[i].startswith("      - name: ")
    )
    return "\n".join(line[10:] for line in lines[run + 1:end]) + "\n"


class PlanDbTypeTests(unittest.TestCase):
    def run_selection(self, state, *, fail_show=False):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            terraform = bin_dir / "terraform"
            terraform.write_text(
                "#!/usr/bin/env bash\n"
                '[[ "$*" == "show -json" ]] || exit 2\n'
                '[[ "$MOCK_FAIL_SHOW" != true ]] || exit 1\n'
                'cat "$MOCK_STATE_FILE"\n'
            )
            terraform.chmod(0o755)
            state_file = root / "state.json"
            state_file.write_text(state)
            output = root / "output"
            env = os.environ.copy()
            env.update(
                PATH=f"{bin_dir}:{env['PATH']}",
                MOCK_STATE_FILE=str(state_file),
                MOCK_FAIL_SHOW="true" if fail_show else "false",
                GITHUB_OUTPUT=str(output),
            )
            result = subprocess.run(
                ["bash", "-c", selection_script()],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            return result, output.read_text() if output.exists() else ""

    def test_uses_fixture_only_when_db_is_absent(self):
        result, output = self.run_selection('{"format_version":"1.0"}')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "value=t4g.medium\n")

    def test_uses_existing_db_instance_type(self):
        state = {
            "format_version": "1.0",
            "values": {"root_module": {"resources": [
                {"address": "aws_instance.load_test_db",
                 "values": {"instance_type": "t4g.large"}}
            ]}},
        }
        result, output = self.run_selection(json.dumps(state))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "value=t4g.large\n")

    def test_refuses_unreadable_state(self):
        result, output = self.run_selection("not-json", fail_show=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, "")

    def test_refuses_db_resource_without_type(self):
        state = {
            "format_version": "1.0",
            "values": {"root_module": {"resources": [
                {"address": "aws_instance.load_test_db", "values": {}}
            ]}},
        }
        result, output = self.run_selection(json.dumps(state))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, "")


if __name__ == "__main__":
    unittest.main()
