#!/usr/bin/env bash
set -euo pipefail

TERRAFORM_DIR="environment/load_test"
VAR_FILE="../../config/secrets/load_test.tfvars"
DATABASE_NAME=""
SWITCH_STAGE_TO_LOADTEST="false"
STAGE_APP_DIR="/home/ubuntu/solid-connection-dev"
STAGE_COMPOSE_FILE="docker-compose.dev.yml"
SSM_COMMAND_TIMEOUT_SECONDS="${SSM_COMMAND_TIMEOUT_SECONDS:-3600}"
SKIP_TERRAFORM_APPLY="false"

usage() {
  cat <<'EOF'
Usage: scripts/load_test/start.sh [options]

Options:
  --terraform-dir PATH          Default: environment/load_test
  --var-file PATH               Default: ../../config/secrets/load_test.tfvars
  --database-name VALUE         Default: Terraform output load_test_db_name
  --switch-stage-to-loadtest    Restart stage app through SSM with dev,loadtest profiles
  --stage-app-dir PATH          Default: /home/ubuntu/solid-connection-dev
  --stage-compose-file VALUE    Default: docker-compose.dev.yml
  --ssm-command-timeout-seconds Default: 3600
  --skip-terraform-apply
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --terraform-dir) TERRAFORM_DIR="$2"; shift 2 ;;
    --var-file) VAR_FILE="$2"; shift 2 ;;
    --database-name) DATABASE_NAME="$2"; shift 2 ;;
    --switch-stage-to-loadtest) SWITCH_STAGE_TO_LOADTEST="true"; shift ;;
    --stage-app-dir) STAGE_APP_DIR="$2"; shift 2 ;;
    --stage-compose-file) STAGE_COMPOSE_FILE="$2"; shift 2 ;;
    --ssm-command-timeout-seconds) SSM_COMMAND_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --skip-terraform-apply) SKIP_TERRAFORM_APPLY="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo "Missing required option: $name" >&2
    exit 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

require_command terraform
require_command aws
require_command jq

tf_output() {
  terraform -chdir="$TERRAFORM_DIR" output -raw "$1"
}

send_ssm_command() {
  local instance_id="$1"
  local comment="$2"
  local commands_json="$3"

  local command_id
  local started_at
  command_id="$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --comment "$comment" \
    --parameters "$commands_json" \
    --query "Command.CommandId" \
    --output text)"
  started_at="$(date +%s)"

  local status
  while true; do
    sleep 5
    status="$(aws ssm get-command-invocation \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query "Status" \
      --output text 2>/dev/null || true)"

    if (( $(date +%s) - started_at > SSM_COMMAND_TIMEOUT_SECONDS )); then
      aws ssm get-command-invocation \
        --command-id "$command_id" \
        --instance-id "$instance_id" \
        --output json || true
      echo "SSM command timed out after ${SSM_COMMAND_TIMEOUT_SECONDS}s: $comment" >&2
      exit 1
    fi

    case "$status" in
      Pending|InProgress|Delayed|"") continue ;;
      Success) break ;;
      *)
        aws ssm get-command-invocation \
          --command-id "$command_id" \
          --instance-id "$instance_id" \
          --output json || true
        echo "SSM command failed with status $status: $comment" >&2
        exit 1
        ;;
    esac
  done
}

wait_for_ssm() {
  local instance_id="$1"
  local started_at
  started_at="$(date +%s)"

  while true; do
    local ping_status
    ping_status="$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=${instance_id}" \
      --query "InstanceInformationList[0].PingStatus" \
      --output text 2>/dev/null || true)"

    if [[ "$ping_status" == "Online" ]]; then
      break
    fi

    if (( $(date +%s) - started_at > SSM_COMMAND_TIMEOUT_SECONDS )); then
      echo "SSM agent did not become online after ${SSM_COMMAND_TIMEOUT_SECONDS}s: ${instance_id}" >&2
      exit 1
    fi

    sleep 10
  done
}

wait_for_load_test_db_restore() {
  local instance_id="$1"
  local commands_json

  commands_json="$(jq -cn \
    '{
      commands: [
        "set -euo pipefail",
        "READY_FILE=/opt/solid-connection/load-test-db-ready",
        "cloud-init status --wait --long || { journalctl -u cloud-final --no-pager -n 200 || true; exit 1; }",
        "test -f \"$READY_FILE\" || { echo \"Load-test DB ready marker was not created: $READY_FILE\" >&2; journalctl -u cloud-final --no-pager -n 200 || true; exit 1; }",
        "cat \"$READY_FILE\""
      ]
    }')"

  wait_for_ssm "$instance_id"
  send_ssm_command "$instance_id" "Wait for load-test DB restore" "$commands_json"
}

if [[ "$SKIP_TERRAFORM_APPLY" != "true" ]]; then
  terraform -chdir="$TERRAFORM_DIR" init
  terraform -chdir="$TERRAFORM_DIR" apply -auto-approve -var-file="$VAR_FILE"
fi

stage_instance_id="$(tf_output stage_api_instance_id)"
stage_public_ip="$(tf_output stage_api_public_ip)"
loadtest_db_instance_id="$(tf_output load_test_db_instance_id)"
loadtest_endpoint="$(tf_output load_test_db_endpoint)"
loadtest_port="$(tf_output load_test_db_port)"
loadtest_db_name="$(tf_output load_test_db_name)"

DATABASE_NAME="${DATABASE_NAME:-$loadtest_db_name}"

wait_for_load_test_db_restore "$loadtest_db_instance_id"

if [[ "$SWITCH_STAGE_TO_LOADTEST" == "true" ]]; then
  stage_commands_json="$(jq -cn \
    --arg app_dir "$STAGE_APP_DIR" \
    --arg compose_file "$STAGE_COMPOSE_FILE" \
    '{
      commands: [
        "set -euo pipefail",
        "cd \($app_dir)",
        "CURRENT_IMAGE=$(docker inspect -f '\''{{.Config.Image}}'\'' solid-connection-dev 2>/dev/null || true)",
        "if [ -z \"$CURRENT_IMAGE\" ]; then echo \"solid-connection-dev container is not running; cannot infer image tag\" >&2; exit 1; fi",
        "OWNER_LOWERCASE=$(echo \"$CURRENT_IMAGE\" | sed -E '\''s#^ghcr.io/([^/]+)/.*#\\1#'\'')",
        "IMAGE_TAG=$(echo \"$CURRENT_IMAGE\" | sed -E '\''s#.*:([^:]+)$#\\1#'\'')",
        "cat > docker-compose.loadtest.override.yml <<'\''YAML'\''\nservices:\n  solid-connection-dev:\n    environment:\n      - SPRING_PROFILES_ACTIVE=dev,loadtest\n      - AWS_REGION=ap-northeast-2\n      - SPRING_DATA_REDIS_HOST=127.0.0.1\n      - SPRING_DATA_REDIS_PORT=6379\nYAML",
        "docker compose -f \($compose_file) -f docker-compose.loadtest.override.yml down || true",
        "OWNER_LOWERCASE=\"$OWNER_LOWERCASE\" IMAGE_TAG=\"$IMAGE_TAG\" docker compose -f \($compose_file) -f docker-compose.loadtest.override.yml up -d solid-connection-dev"
      ]
    }')"

  send_ssm_command "$stage_instance_id" "Switch stage app to load test datasource" "$stage_commands_json"
fi

echo "Load test environment is ready."
echo "DB endpoint: ${loadtest_endpoint}:${loadtest_port}"
echo "Load generator instance: created by Load Test Run"
echo "Stage instance: ${stage_instance_id}"
echo "Stage public IP: ${stage_public_ip}"
