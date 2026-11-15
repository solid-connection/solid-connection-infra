"""Guard tests for the load-test entry points without AWS or Terraform changes."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class WorkflowGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.log"
        self._command(
            "terraform",
            r'''#!/usr/bin/env bash
printf 'terraform %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  *"output -raw stage_api_instance_id"*) echo i-stage ;;
  *"output -raw load_test_db_instance_type"*)
    if [[ "${MOCK_OLD_STATE:-false}" == true ]]; then exit 1; fi
    echo t4g.large ;;
  *"show -json"*) echo '{"values":{"root_module":{"resources":[{"address":"aws_instance.load_test_db","values":{"instance_type":"t4g.large"}}]}}}' ;;
esac
''',
        )
        self._command(
            "aws",
            r'''#!/usr/bin/env bash
printf 'aws %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  *"ssm send-command"*) echo command-123 ;;
  *"ssm get-command-invocation"*"--query Status"*) echo "$MOCK_SSM_STATUS" ;;
esac
''',
        )
        self._command("sleep", "#!/usr/bin/env bash\nexit 0\n")

    def _command(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_script(self, name, *args, status="Success", old_state=False):
        env = os.environ.copy()
        env.update(
            PATH=f"{self.bin}:{env['PATH']}",
            MOCK_LOG=str(self.log),
            MOCK_SSM_STATUS=status,
            MOCK_OLD_STATE="true" if old_state else "false",
        )
        result = subprocess.run(
            ["bash", f"scripts/load_test/{name}.sh", *args],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        calls = self.log.read_text().splitlines() if self.log.exists() else []
        return result, calls

    def test_start_requires_db_type_before_terraform(self):
        result, calls = self.run_script("start")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--db-instance-type", result.stderr)
        self.assertFalse(any(call.startswith("terraform ") for call in calls))

    def test_stop_rejects_destroy_without_restore(self):
        result, calls = self.run_script("stop")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Destroy requires", result.stderr)
        self.assertFalse(any(call.startswith("terraform ") for call in calls))

    def test_stop_keeps_db_when_stage_restore_fails(self):
        result, calls = self.run_script("stop", "--restore-stage-dev", status="Failed")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(" destroy " in call for call in calls))

    def test_stop_uses_selected_type_after_successful_restore(self):
        result, calls = self.run_script("stop", "--restore-stage-dev")
        self.assertEqual(result.returncode, 0, result.stderr)
        stage_status = next(i for i, call in enumerate(calls) if "--query Status" in call)
        destroy = next(i for i, call in enumerate(calls) if " destroy " in call)
        self.assertLess(stage_status, destroy)
        self.assertIn("-var=load_test_db_instance_type=t4g.large", calls[destroy])

    def test_stop_can_read_type_from_state_before_output_was_added(self):
        result, calls = self.run_script("stop", "--restore-stage-dev", old_state=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any("show -json" in call for call in calls))
        self.assertTrue(any("-var=load_test_db_instance_type=t4g.large" in call for call in calls))


if __name__ == "__main__":
    unittest.main()
