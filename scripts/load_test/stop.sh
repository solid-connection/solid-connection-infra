#!/usr/bin/env bash
set -euo pipefail

TERRAFORM_DIR="environment/load_test"
VAR_FILE="../../config/secrets/load_test.tfvars"
STAGE_START_COMMAND=""
RESTORE_STAGE_DEV="false"
STAGE_SSH_USER="ubuntu"
STAGE_SSH_KEY=""
STAGE_APP_DIR="/home/ubuntu/solid-connection-dev"
STAGE_COMPOSE_FILE="docker-compose.dev.yml"
SKIP_TERRAFORM_DESTROY="false"

usage() {
  cat <<'EOF'
Usage: scripts/load_test/stop.sh [options]

Options:
  --terraform-dir PATH           Default: environment/load_test
  --var-file PATH                Default: ../../config/secrets/load_test.tfvars
  --restore-stage-dev            Restart stage app over SSH with dev profile
  --stage-ssh-user VALUE         Default: ubuntu
  --stage-ssh-key PATH           Required with --restore-stage-dev
  --stage-app-dir PATH           Default: /home/ubuntu/solid-connection-dev
  --stage-compose-file VALUE     Default: docker-compose.dev.yml
  --skip-terraform-destroy
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --terraform-dir) TERRAFORM_DIR="$2"; shift 2 ;;
    --var-file) VAR_FILE="$2"; shift 2 ;;
    --restore-stage-dev) RESTORE_STAGE_DEV="true"; shift ;;
    --stage-ssh-user) STAGE_SSH_USER="$2"; shift 2 ;;
    --stage-ssh-key) STAGE_SSH_KEY="$2"; shift 2 ;;
    --stage-app-dir) STAGE_APP_DIR="$2"; shift 2 ;;
    --stage-compose-file) STAGE_COMPOSE_FILE="$2"; shift 2 ;;
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
require_command ssh

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo "Missing required option: $name" >&2
    exit 1
  fi
}

tf_output() {
  terraform -chdir="$TERRAFORM_DIR" output -raw "$1"
}

send_ssm_command() {
  local instance_id="$1"
  local comment="$2"
  local commands_json="$3"

  local command_id
  command_id="$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --comment "$comment" \
    --parameters "$commands_json" \
    --query "Command.CommandId" \
    --output text)"

  local status
  while true; do
    sleep 5
    status="$(aws ssm get-command-invocation \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query "Status" \
      --output text 2>/dev/null || true)"

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

if [[ "$RESTORE_STAGE_DEV" == "true" ]]; then
  require_value "--stage-ssh-key" "$STAGE_SSH_KEY"
  stage_public_ip="$(tf_output stage_api_public_ip)"

  ssh -i "$STAGE_SSH_KEY" \
    -o StrictHostKeyChecking=no \
    "$STAGE_SSH_USER@$stage_public_ip" \
    "APP_DIR='$STAGE_APP_DIR' COMPOSE_FILE='$STAGE_COMPOSE_FILE' bash -s" <<'REMOTE'
set -euo pipefail

cd "$APP_DIR"

CURRENT_IMAGE="$(docker inspect -f '{{.Config.Image}}' solid-connection-dev 2>/dev/null || true)"
if [[ -z "$CURRENT_IMAGE" ]]; then
  echo "solid-connection-dev container is not running; cannot infer image tag" >&2
  exit 1
fi

OWNER_LOWERCASE="$(echo "$CURRENT_IMAGE" | sed -E 's#^ghcr.io/([^/]+)/.*#\1#')"
IMAGE_TAG="$(echo "$CURRENT_IMAGE" | sed -E 's#.*:([^:]+)$#\1#')"

rm -f docker-compose.loadtest.override.yml
docker compose -f "$COMPOSE_FILE" down || true
OWNER_LOWERCASE="$OWNER_LOWERCASE" IMAGE_TAG="$IMAGE_TAG" docker compose -f "$COMPOSE_FILE" up -d
REMOTE
fi

if [[ "$SKIP_TERRAFORM_DESTROY" != "true" ]]; then
  terraform -chdir="$TERRAFORM_DIR" destroy -auto-approve -var-file="$VAR_FILE"
fi

echo "Load test environment has been stopped."
