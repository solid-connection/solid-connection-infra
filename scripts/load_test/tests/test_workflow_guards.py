"""Guard tests for the load-test entry points without AWS or Terraform changes."""

import json
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
        self.ssm_parameters = self.root / "ssm-parameters.json"
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
  *"ssm send-command"*)
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--parameters" ]]; then
        printf '%s' "$2" > "$MOCK_SSM_PARAMETERS"
        break
      fi
      shift
    done
    echo command-123 ;;
  *"ssm describe-instance-information"*) echo Online ;;
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
            MOCK_SSM_PARAMETERS=str(self.ssm_parameters),
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

    def assert_stage_ssm_payload_runs(self, expected_mode):
        command = json.loads(self.ssm_parameters.read_text())["commands"][0]
        self.assertIn(f"STAGE_MODE={expected_mode} ", command)
        lines = command.splitlines()
        self.assertEqual(lines[-1], "STAGE_APP_SCRIPT")
        self.assertEqual("\n".join(lines[1:-1]), (ROOT / "scripts/load_test/stage_app.sh").read_text())
        probe = "\n".join((lines[0], "printf 'payload-ok\\n'", lines[-1]))
        result = subprocess.run(["bash", "-c", probe], text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "payload-ok\n")

    def test_start_requires_db_type_before_terraform(self):
        result, calls = self.run_script("start")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--db-instance-type", result.stderr)
        self.assertFalse(any(call.startswith("terraform ") for call in calls))

    def test_start_stage_ssm_payload_has_working_heredoc(self):
        result, _ = self.run_script("start", "--skip-terraform-apply", "--switch-stage-to-loadtest")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_stage_ssm_payload_runs("loadtest")

    def test_stop_rejects_destroy_without_restore(self):
        result, calls = self.run_script("stop")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Destroy requires", result.stderr)
        self.assertFalse(any(call.startswith("terraform ") for call in calls))

    def test_stop_stage_ssm_payload_has_working_heredoc(self):
        result, _ = self.run_script("stop", "--restore-stage-dev", "--skip-terraform-destroy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_stage_ssm_payload_runs("dev")

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
