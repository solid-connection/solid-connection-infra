#!/usr/bin/env bash
set -euo pipefail

TERRAFORM_DIR="environment/load_test"
VAR_FILE="../../config/secrets/load_test.tfvars"
RESTORE_STAGE_DEV="false"
STAGE_APP_DIR="/home/ubuntu/solid-connection-dev"
STAGE_COMPOSE_FILE="docker-compose.dev.yml"
SSM_COMMAND_TIMEOUT_SECONDS="${SSM_COMMAND_TIMEOUT_SECONDS:-900}"
SKIP_TERRAFORM_DESTROY="false"
DB_INSTANCE_TYPE=""

usage() {
  cat <<'EOF'
Usage: scripts/load_test/stop.sh [options]

Options:
  --terraform-dir PATH           Default: environment/load_test
  --var-file PATH                Default: ../../config/secrets/load_test.tfvars
  --restore-stage-dev            Restart stage app through SSM with dev profile
  --stage-app-dir PATH           Default: /home/ubuntu/solid-connection-dev
  --stage-compose-file VALUE     Default: docker-compose.dev.yml
  --db-instance-type VALUE       Required only if Start failed before the DB EC2 entered state
  --ssm-command-timeout-seconds  Default: 900
  --skip-terraform-destroy
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --terraform-dir) TERRAFORM_DIR="$2"; shift 2 ;;
    --var-file) VAR_FILE="$2"; shift 2 ;;
    --restore-stage-dev) RESTORE_STAGE_DEV="true"; shift ;;
    --stage-app-dir) STAGE_APP_DIR="$2"; shift 2 ;;
    --stage-compose-file) STAGE_COMPOSE_FILE="$2"; shift 2 ;;
    --db-instance-type) DB_INSTANCE_TYPE="$2"; shift 2 ;;
    --ssm-command-timeout-seconds) SSM_COMMAND_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --skip-terraform-destroy) SKIP_TERRAFORM_DESTROY="true"; shift ;;
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

if [[ "$RESTORE_STAGE_DEV" != "true" && "$SKIP_TERRAFORM_DESTROY" != "true" ]]; then
  echo "Destroy requires --restore-stage-dev so stage cannot lose its DB" >&2
  exit 1
fi

source scripts/load_test/terraform_db_type.sh

tf_output() {
  terraform -chdir="$TERRAFORM_DIR" output -raw "$1"
}

stage_api_instance_id_from_state() {
  local value
  value="$(tf_output stage_api_instance_id 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    value="$(terraform -chdir="$TERRAFORM_DIR" show -json | jq -r '
      first(.values.root_module.resources[]?
        | select(.address == "data.aws_instance.stage_api")
        | .values.id) // empty
    ')"
  fi
  if [[ -z "$value" ]]; then
    echo "Cannot identify the stage API instance from Terraform state; refusing to destroy" >&2
    return 1
  fi
  printf '%s\n' "$value"
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

terraform -chdir="$TERRAFORM_DIR" init

if [[ "$RESTORE_STAGE_DEV" == "true" ]]; then
  stage_instance_id="$(stage_api_instance_id_from_state)"

  stage_commands_json="$(jq -cn \
    --arg app_dir "$STAGE_APP_DIR" \
    --arg compose_file "$STAGE_COMPOSE_FILE" \
    --rawfile script scripts/load_test/stage_app.sh \
    '{
      commands: [
        "STAGE_MODE=dev STAGE_APP_DIR=\($app_dir | @sh) STAGE_COMPOSE_FILE=\($compose_file | @sh) bash -s <<\\STAGE_APP_SCRIPT\n\($script)\nSTAGE_APP_SCRIPT"
      ]
    }')"

  send_ssm_command "$stage_instance_id" "Restore stage app to dev datasource" "$stage_commands_json"
fi

if [[ "$SKIP_TERRAFORM_DESTROY" != "true" ]]; then
  db_instance_type="$(load_test_db_instance_type_from_state 2>/dev/null || true)"
  if [[ -z "$db_instance_type" ]]; then
    if [[ -z "$DB_INSTANCE_TYPE" ]]; then
      echo "DB EC2 is absent from state; pass --db-instance-type to destroy the partial stack" >&2
      exit 1
    fi
    db_instance_type="$DB_INSTANCE_TYPE"
  elif [[ -n "$DB_INSTANCE_TYPE" && "$DB_INSTANCE_TYPE" != "$db_instance_type" ]]; then
    echo "Provided DB instance type differs from Terraform state: $db_instance_type" >&2
    exit 1
  fi
  terraform -chdir="$TERRAFORM_DIR" destroy -auto-approve -var-file="$VAR_FILE" \
    -var="load_test_db_instance_type=$db_instance_type"
fi

echo "Load test environment has been stopped."
