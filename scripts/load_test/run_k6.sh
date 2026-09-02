#!/usr/bin/env bash
set -euo pipefail

TERRAFORM_DIR="environment/load_test"
VAR_FILE="../../config/secrets/load_test.tfvars"
LOCAL_K6_DIR="config/load-test/k6"
K6_SCRIPT="whole-user-flow.js"
SCRIPT_PROVIDED="false"
GENERATE_BRUNO_SCRIPT="false"
BRUNO_COLLECTION_DIR=""
BRUNO_GENERATOR="scripts/load_test/generate_bruno_k6.py"
TARGET_BASE_URL=""
PROMETHEUS_REMOTE_WRITE_URL=""
K6_VUS="10"
K6_ITERATIONS="10"
K6_MAX_DURATION="15m"
SSM_COMMAND_TIMEOUT_SECONDS="${SSM_COMMAND_TIMEOUT_SECONDS:-3600}"
SSM_COMMAND_PAYLOAD_MAX_BYTES="${SSM_COMMAND_PAYLOAD_MAX_BYTES:-60000}"
SSM_FILE_SYNC_CHUNK_BYTES="${SSM_FILE_SYNC_CHUNK_BYTES:-48000}"
DESTROY_RUNNER="true"
REBUILD_K6="false"

usage() {
  cat <<'EOF'
Usage: scripts/load_test/run_k6.sh [options]

Options:
  --terraform-dir PATH              Default: environment/load_test
  --var-file PATH                   Default: ../../config/secrets/load_test.tfvars
  --local-k6-dir PATH               Default: config/load-test/k6
  --script FILE                     Default: whole-user-flow.js
  --generate-bruno-script           Generate the selected script from a Bruno collection
  --bruno-collection-dir PATH       Required when --generate-bruno-script is used
  --bruno-generator PATH            Default: scripts/load_test/generate_bruno_k6.py
  --target-base-url URL             Default: Terraform output load_test_target_base_url
  --prometheus-remote-write-url URL Default: Terraform output k6_prometheus_remote_write_url
  --vus VALUE                       Default: 10
  --iterations VALUE                Default: 10
  --max-duration VALUE              Default: 15m
  --ssm-command-timeout-seconds     Default: 3600
  --skip-runner-destroy             Keep the k6 load generator after the run
  --rebuild-k6                      Rebuild the k6 binary before running
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --terraform-dir) TERRAFORM_DIR="$2"; shift 2 ;;
    --var-file) VAR_FILE="$2"; shift 2 ;;
    --local-k6-dir) LOCAL_K6_DIR="$2"; shift 2 ;;
    --script) K6_SCRIPT="$2"; SCRIPT_PROVIDED="true"; shift 2 ;;
    --generate-bruno-script) GENERATE_BRUNO_SCRIPT="true"; shift ;;
    --bruno-collection-dir) BRUNO_COLLECTION_DIR="$2"; shift 2 ;;
    --bruno-generator) BRUNO_GENERATOR="$2"; shift 2 ;;
    --target-base-url) TARGET_BASE_URL="$2"; shift 2 ;;
    --prometheus-remote-write-url) PROMETHEUS_REMOTE_WRITE_URL="$2"; shift 2 ;;
    --vus) K6_VUS="$2"; shift 2 ;;
    --iterations) K6_ITERATIONS="$2"; shift 2 ;;
    --max-duration) K6_MAX_DURATION="$2"; shift 2 ;;
    --ssm-command-timeout-seconds) SSM_COMMAND_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --skip-runner-destroy) DESTROY_RUNNER="false"; shift ;;
    --rebuild-k6) REBUILD_K6="true"; shift ;;
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
require_command find
require_command fold
require_command gzip
require_command wc
if [[ "$GENERATE_BRUNO_SCRIPT" == "true" ]]; then
  require_command python3
fi

if [[ "$GENERATE_BRUNO_SCRIPT" == "true" && "$SCRIPT_PROVIDED" != "true" ]]; then
  K6_SCRIPT="bruno-all-apis.js"
fi

if [[ "$GENERATE_BRUNO_SCRIPT" == "true" && -z "$BRUNO_COLLECTION_DIR" ]]; then
  echo "--bruno-collection-dir is required when --generate-bruno-script is used" >&2
  exit 1
fi

if [[ "$GENERATE_BRUNO_SCRIPT" == "true" && ! -f "$BRUNO_GENERATOR" ]]; then
  echo "Bruno k6 generator was not found: $BRUNO_GENERATOR" >&2
  exit 1
fi

tf_output() {
  terraform -chdir="$TERRAFORM_DIR" output -raw "$1"
}

runner_targets=(
  -target=aws_security_group.load_generator
  -target=aws_instance.load_generator
)

destroy_runner() {
  local exit_code="$?"
  local cleanup_code=0

  if [[ "$DESTROY_RUNNER" == "true" ]]; then
    terraform -chdir="$TERRAFORM_DIR" destroy -auto-approve -var-file="$VAR_FILE" "${runner_targets[@]}" || cleanup_code="$?"
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    exit "$exit_code"
  fi

  exit "$cleanup_code"
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

file_gzip_base64() {
  gzip -c "$1" | base64 | tr -d '\n'
}

json_size_bytes() {
  printf '%s' "$1" | wc -c
}

ensure_ssm_payload_size() {
  local commands_json="$1"
  local size_bytes
  size_bytes="$(json_size_bytes "$commands_json")"

  if (( size_bytes > SSM_COMMAND_PAYLOAD_MAX_BYTES )); then
    echo "SSM command payload is too large: ${size_bytes} bytes, max ${SSM_COMMAND_PAYLOAD_MAX_BYTES} bytes" >&2
    exit 1
  fi
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

  local target_path="${target_dir}/${relative_path}"
  local encoded_content
  encoded_content="$(file_gzip_base64 "$source_path")"

  local commands_json
  commands_json="$(jq -cn \
    --arg target "$target_path" \
    --arg content "$encoded_content" \
    '{
      commands: [
        "set -euo pipefail",
        "mkdir -p \"$(dirname \"\($target)\")\"",
        "printf %s \($content | @sh) | base64 -d | gzip -dc > \($target | @sh)"
      ]
    }')"

  if (( $(json_size_bytes "$commands_json") <= SSM_COMMAND_PAYLOAD_MAX_BYTES )); then
    send_ssm_command "$instance_id" "Sync ${relative_path} to load generator" "$commands_json"
    return
  fi

  local remote_tmp="${target_path}.b64.part"
  commands_json="$(jq -cn \
    --arg target "$target_path" \
    --arg remote_tmp "$remote_tmp" \
    '{
      commands: [
        "set -euo pipefail",
        "mkdir -p \"$(dirname \"\($target)\")\"",
        "rm -f \($remote_tmp | @sh)"
      ]
    }')"
  ensure_ssm_payload_size "$commands_json"
  send_ssm_command "$instance_id" "Prepare chunked sync for ${relative_path}" "$commands_json"

  while IFS= read -r chunk; do
    commands_json="$(jq -cn \
      --arg remote_tmp "$remote_tmp" \
      --arg chunk "$chunk" \
      '{
        commands: [
          "set -euo pipefail",
          "printf %s \($chunk | @sh) >> \($remote_tmp | @sh)"
        ]
      }')"
    ensure_ssm_payload_size "$commands_json"
    send_ssm_command "$instance_id" "Sync chunk for ${relative_path}" "$commands_json"
  done < <(printf '%s' "$encoded_content" | fold -w "$SSM_FILE_SYNC_CHUNK_BYTES")

  commands_json="$(jq -cn \
    --arg target "$target_path" \
    --arg remote_tmp "$remote_tmp" \
    '{
      commands: [
        "set -euo pipefail",
        "base64 -d < \($remote_tmp | @sh) | gzip -dc > \($target | @sh)",
        "rm -f \($remote_tmp | @sh)"
      ]
    }')"
  ensure_ssm_payload_size "$commands_json"
  send_ssm_command "$instance_id" "Finish chunked sync for ${relative_path}" "$commands_json"
}

terraform -chdir="$TERRAFORM_DIR" init
terraform -chdir="$TERRAFORM_DIR" apply -auto-approve -var-file="$VAR_FILE" "${runner_targets[@]}"

trap destroy_runner EXIT

load_generator_instance_id="$(tf_output load_generator_instance_id)"
load_generator_k6_dir="$(tf_output load_generator_k6_dir)"
tf_target_base_url="$(tf_output load_test_target_base_url)"
tf_prometheus_remote_write_url="$(tf_output k6_prometheus_remote_write_url)"

TARGET_BASE_URL="${TARGET_BASE_URL:-$tf_target_base_url}"
PROMETHEUS_REMOTE_WRITE_URL="${PROMETHEUS_REMOTE_WRITE_URL:-$tf_prometheus_remote_write_url}"

wait_for_ssm "$load_generator_instance_id"

if [[ "$GENERATE_BRUNO_SCRIPT" == "true" ]]; then
  python3 "$BRUNO_GENERATOR" \
    --collection-dir "$BRUNO_COLLECTION_DIR" \
    --output "${LOCAL_K6_DIR}/${K6_SCRIPT}"
fi

if [[ ! -f "${LOCAL_K6_DIR}/${K6_SCRIPT}" ]]; then
  echo "Missing k6 script: ${LOCAL_K6_DIR}/${K6_SCRIPT}" >&2
  exit 1
fi

while IFS= read -r -d '' source_path; do
  relative_path="${source_path#"$LOCAL_K6_DIR"/}"
  sync_file "$load_generator_instance_id" "$load_generator_k6_dir" "$relative_path"
done < <(find "$LOCAL_K6_DIR" -type f \( -name '*.js' -o -name '*.ts' -o -name '*.json' -o -name '*.sh' \) -print0)

run_commands_json="$(jq -cn \
  --arg k6_dir "$load_generator_k6_dir" \
  --arg script "$K6_SCRIPT" \
  --arg target_base_url "$TARGET_BASE_URL" \
  --arg prometheus_url "$PROMETHEUS_REMOTE_WRITE_URL" \
  --arg vus "$K6_VUS" \
  --arg iterations "$K6_ITERATIONS" \
  --arg max_duration "$K6_MAX_DURATION" \
  --arg rebuild_k6 "$REBUILD_K6" \
  '{
    commands: [
      "set -euo pipefail",
      "cd \($k6_dir)",
      "pkill -f '\''(^|/)k6( |$)'\'' || true",
      "chmod +x set_up_xk6.sh",
      "chown -R ubuntu:ubuntu \($k6_dir)",
      "if [ \($rebuild_k6 | @sh) = '\''true'\'' ]; then rm -f ./k6; fi",
      "if [ ! -x ./k6 ]; then sudo -u ubuntu -H ./set_up_xk6.sh; fi",
      "sudo -u ubuntu -H env BASE_URL=\($target_base_url | @sh) K6_PROMETHEUS_RW_SERVER_URL=\($prometheus_url | @sh) K6_PROMETHEUS_RW_TREND_STATS=\"p(90),p(95),p(99),avg,min,max\" K6_VUS=\($vus | @sh) K6_ITERATIONS=\($iterations | @sh) K6_MAX_DURATION=\($max_duration | @sh) ./k6 run \(if $prometheus_url != \"\" then \"-o experimental-prometheus-rw \" else \"\" end)\($script | @sh)"
    ]
  }')"

send_ssm_command "$load_generator_instance_id" "Run k6 load test" "$run_commands_json"
