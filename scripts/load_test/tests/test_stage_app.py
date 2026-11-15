"""Behavior tests for the shell script sent to the stage EC2 through SSM."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/load_test/stage_app.sh"


class StageAppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.root / "docker-compose.dev.yml").write_text("services: {}\n")
        self.upstream = self.root / "upstream.conf"
        self.log = self.root / "calls.log"
        self.mode = self.root / "app-mode"
        self._command(
            "docker",
            r'''#!/usr/bin/env bash
set -e
printf 'docker %s\n' "$*" >> "$MOCK_LOG"
if [[ "$1" == "inspect" ]]; then
  case "$4" in
    solid-connection-dev-mysql)
      case "$3" in
        *State.Running*) echo true ;;
        *compose.project*) echo solid-connection-dev ;;
      esac ;;
    solid-connection-dev-blue|solid-connection-dev-green)
      case "$3" in
        *State.Running*) echo true ;;
        *compose.project*) echo "$4" ;;
        *Config.Image*) echo ghcr.io/solid-connection/solid-connection-dev:tag-123 ;;
      esac ;;
  esac
elif [[ "$1" == "compose" ]]; then
  action=""
  service="${!#}"
  for arg in "$@"; do
    [[ "$arg" == "up" || "$arg" == "stop" ]] && action="$arg"
  done
  if [[ "$action" == "up" && "$service" == "solid-connection-dev" ]]; then
    if [[ "$*" == *".docker-compose.loadtest."* ]]; then
      echo loadtest > "$MOCK_MODE"
    else
      echo dev > "$MOCK_MODE"
    fi
  elif [[ "$action" == "stop" && "$service" == "mysql" ]]; then
    touch "$MOCK_MYSQL_STOPPED"
  fi
elif [[ "$1" == "exec" ]]; then
  [[ "${MOCK_MYSQL_FAIL:-false}" != true ]]
fi
''',
        )
        self._command(
            "curl",
            r'''#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$MOCK_LOG"
mode="$(cat "$MOCK_MODE")"
if [[ "${MOCK_FAIL_AFTER_MYSQL_STOP:-false}" == true && "$mode" == loadtest && -f "$MOCK_MYSQL_STOPPED" ]]; then
  exit 22
fi
[[ "$mode" != "${MOCK_FAIL_MODE:-none}" ]]
''',
        )

    def _command(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_stage(self, mode, port, *, fail_mode="none", mysql_fail=False, fail_after_mysql_stop=False):
        self.upstream.write_text(
            f"upstream app_backend {{\n    server 127.0.0.1:{port};\n}}\n"
        )
        self.mode.write_text("dev" if mode == "loadtest" else "loadtest")
        env = os.environ.copy()
        env.update(
            PATH=f"{self.bin}:{env['PATH']}",
            STAGE_MODE=mode,
            STAGE_APP_DIR=str(self.root),
            STAGE_COMPOSE_FILE="docker-compose.dev.yml",
            STAGE_UPSTREAM_FILE=str(self.upstream),
            STAGE_HEALTH_ATTEMPTS="2",
            STAGE_MYSQL_ATTEMPTS="2",
            STAGE_HEALTH_INTERVAL_SECONDS="0",
            MOCK_LOG=str(self.log),
            MOCK_MODE=str(self.mode),
            MOCK_MYSQL_STOPPED=str(self.root / "mysql-stopped"),
            MOCK_FAIL_MODE=fail_mode,
            MOCK_MYSQL_FAIL="true" if mysql_fail else "false",
            MOCK_FAIL_AFTER_MYSQL_STOP="true" if fail_after_mysql_stop else "false",
        )
        result = subprocess.run(
            ["bash", str(SCRIPT)], env=env, text=True, capture_output=True, check=False
        )
        calls = self.log.read_text().splitlines() if self.log.exists() else []
        return result, calls

    def test_loadtest_recreates_only_active_slot_then_stops_mysql(self):
        for port, slot, management in [(8080, "blue", 8081), (9080, "green", 9081)]:
            with self.subTest(slot=slot):
                self.log.unlink(missing_ok=True)
                result, calls = self.run_stage("loadtest", port)
                self.assertEqual(result.returncode, 0, result.stderr)
                app_up = next(i for i, call in enumerate(calls) if "up -d --no-deps --force-recreate solid-connection-dev" in call)
                health = next(i for i, call in enumerate(calls) if f":{management}/actuator/health" in call)
                mysql_stop = next(i for i, call in enumerate(calls) if "stop mysql" in call)
                self.assertIn(f"-p solid-connection-dev-{slot}", calls[app_up])
                self.assertLess(app_up, health)
                self.assertLess(health, mysql_stop)
                self.assertFalse(any(" down" in call for call in calls))

    def test_invalid_upstream_fails_before_compose(self):
        result, calls = self.run_stage("loadtest", 7777)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("docker compose" in call for call in calls))

    def test_failed_loadtest_health_restores_dev_and_mysql(self):
        result, calls = self.run_stage("loadtest", 8080, fail_mode="loadtest")
        self.assertNotEqual(result.returncode, 0)
        mysql_start = next(i for i, call in enumerate(calls) if "start mysql" in call)
        dev_up = max(i for i, call in enumerate(calls) if "up -d --no-deps --force-recreate solid-connection-dev" in call)
        self.assertLess(mysql_start, dev_up)
        self.assertEqual(self.mode.read_text().strip(), "dev")

    def test_loadtest_unhealthy_after_mysql_stop_restores_dev(self):
        result, calls = self.run_stage("loadtest", 8080, fail_after_mysql_stop=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.mode.read_text().strip(), "dev")
        self.assertTrue(any("stop mysql" in call for call in calls))
        self.assertTrue(any("start mysql" in call for call in calls))

    def test_stop_starts_mysql_before_dev_app(self):
        result, calls = self.run_stage("dev", 9080)
        self.assertEqual(result.returncode, 0, result.stderr)
        mysql_start = next(i for i, call in enumerate(calls) if "start mysql" in call)
        mysql_ping = next(i for i, call in enumerate(calls) if "mysqladmin ping" in call)
        dev_up = next(i for i, call in enumerate(calls) if "up -d --no-deps --force-recreate solid-connection-dev" in call)
        self.assertLess(mysql_start, mysql_ping)
        self.assertLess(mysql_ping, dev_up)
        self.assertEqual(self.mode.read_text().strip(), "dev")

    def test_failed_dev_health_returns_failure(self):
        result, calls = self.run_stage("dev", 8080, fail_mode="dev")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.mode.read_text().strip(), "loadtest")
        self.assertTrue(any(".docker-compose.loadtest." in call for call in calls))
        self.assertTrue(any("stop mysql" in call for call in calls))

    def test_mysql_not_ready_prevents_dev_switch(self):
        result, calls = self.run_stage("dev", 8080, mysql_fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("docker compose" in call and "up -d --no-deps --force-recreate solid-connection-dev" in call and ".docker-compose.loadtest." not in call for call in calls))


if __name__ == "__main__":
    unittest.main()
