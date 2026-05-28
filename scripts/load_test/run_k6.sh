#!/usr/bin/env bash
set -euo pipefail

TERRAFORM_DIR="environment/load_test"
LOCAL_K6_DIR="config/load-test/k6"
K6_SCRIPT="whole-user-flow.js"
TARGET_BASE_URL=""
PROMETHEUS_REMOTE_WRITE_URL=""
K6_VUS="10"
K6_ITERATIONS="10"
K6_MAX_DURATION="15m"
SSM_COMMAND_TIMEOUT_SECONDS="${SSM_COMMAND_TIMEOUT_SECONDS:-3600}"

usage() {
  cat <<'EOF'
Usage: scripts/load_test/run_k6.sh [options]

Options:
  --terraform-dir PATH              Default: environment/load_test
  --local-k6-dir PATH               Default: config/load-test/k6
  --script FILE                     Default: whole-user-flow.js
  --target-base-url URL             Default: Terraform output load_test_target_base_url
  --prometheus-remote-write-url URL Default: Terraform output k6_prometheus_remote_write_url
  --vus VALUE                       Default: 10
  --iterations VALUE                Default: 10
  --max-duration VALUE              Default: 15m
  --ssm-command-timeout-seconds     Default: 3600
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --terraform-dir) TERRAFORM_DIR="$2"; shift 2 ;;
    --local-k6-dir) LOCAL_K6_DIR="$2"; shift 2 ;;
    --script) K6_SCRIPT="$2"; shift 2 ;;
    --target-base-url) TARGET_BASE_URL="$2"; shift 2 ;;
    --prometheus-remote-write-url) PROMETHEUS_REMOTE_WRITE_URL="$2"; shift 2 ;;
    --vus) K6_VUS="$2"; shift 2 ;;
    --iterations) K6_ITERATIONS="$2"; shift 2 ;;
    --max-duration) K6_MAX_DURATION="$2"; shift 2 ;;
    --ssm-command-timeout-seconds) SSM_COMMAND_TIMEOUT_SECONDS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

require_command terraform
require_command aws
require_command jq
require_command base64

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
      Success)
        aws ssm get-command-invocation \
          --command-id "$command_id" \
          --instance-id "$instance_id" \
          --query "StandardOutputContent" \
          --output text || true
        break
        ;;
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

file_base64() {
  base64 "$1" | tr -d '\n'
}

sync_file() {
  local instance_id="$1"
  local target_dir="$2"
  local relative_path="$3"
  local source_path="${LOCAL_K6_DIR}/${relative_path}"

  if [[ ! -f "$source_path" ]]; then
    echo "Missing k6 file: $source_path" >&2
    exit 1
  fi

  local commands_json
  commands_json="$(jq -cn \
    --arg target "${target_dir}/${relative_path}" \
    --arg content "$(file_base64 "$source_path")" \
    '{
      commands: [
        "set -euo pipefail",
        "mkdir -p \"$(dirname \"\($target)\")\"",
        "printf %s \($content | @sh) | base64 -d > \($target | @sh)"
      ]
    }')"

  send_ssm_command "$instance_id" "Sync ${relative_path} to load generator" "$commands_json"
}

terraform -chdir="$TERRAFORM_DIR" init

load_generator_instance_id="$(tf_output load_generator_instance_id)"
load_generator_k6_dir="$(tf_output load_generator_k6_dir)"
tf_target_base_url="$(tf_output load_test_target_base_url)"
tf_prometheus_remote_write_url="$(tf_output k6_prometheus_remote_write_url)"

TARGET_BASE_URL="${TARGET_BASE_URL:-$tf_target_base_url}"
PROMETHEUS_REMOTE_WRITE_URL="${PROMETHEUS_REMOTE_WRITE_URL:-$tf_prometheus_remote_write_url}"

wait_for_ssm "$load_generator_instance_id"

for relative_path in \
  "createPost.json" \
  "updatePost.json" \
  "whole-user-flow.js" \
  "set_up_xk6.sh"; do
  sync_file "$load_generator_instance_id" "$load_generator_k6_dir" "$relative_path"
done

run_commands_json="$(jq -cn \
  --arg k6_dir "$load_generator_k6_dir" \
  --arg script "$K6_SCRIPT" \
  --arg target_base_url "$TARGET_BASE_URL" \
  --arg prometheus_url "$PROMETHEUS_REMOTE_WRITE_URL" \
  --arg vus "$K6_VUS" \
  --arg iterations "$K6_ITERATIONS" \
  --arg max_duration "$K6_MAX_DURATION" \
  '{
    commands: [
      "set -euo pipefail",
      "cd \($k6_dir)",
      "chmod +x set_up_xk6.sh",
      "chown -R ubuntu:ubuntu \($k6_dir)",
      "if [ ! -x ./k6 ]; then sudo -u ubuntu -H ./set_up_xk6.sh; fi",
      "sudo -u ubuntu -H env BASE_URL=\($target_base_url | @sh) K6_PROMETHEUS_RW_SERVER_URL=\($prometheus_url | @sh) K6_VUS=\($vus | @sh) K6_ITERATIONS=\($iterations | @sh) K6_MAX_DURATION=\($max_duration | @sh) ./k6 run \($script | @sh)"
    ]
  }')"

send_ssm_command "$load_generator_instance_id" "Run k6 load test" "$run_commands_json"
