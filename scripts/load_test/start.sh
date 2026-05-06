#!/usr/bin/env bash
set -euo pipefail

TERRAFORM_DIR="environment/load_test"
VAR_FILE="../../config/secrets/load_test.tfvars"
DATABASE_NAME=""
MIGRATION_PARAMETER_PREFIX="/solid-connection/loadtest/migration"
PROD_DB_USERNAME_PARAMETER=""
PROD_DB_PASSWORD_PARAMETER=""
LOADTEST_DB_USERNAME_PARAMETER=""
LOADTEST_DB_PASSWORD_PARAMETER=""
SWITCH_STAGE_TO_LOADTEST="false"
STAGE_APP_DIR="/home/ubuntu/solid-connection-dev"
STAGE_COMPOSE_FILE="docker-compose.dev.yml"
STAGE_K6_DIR="/home/ubuntu/solid-connection-load-test/k6"
LOCAL_K6_DIR="config/load-test/k6"
SSM_COMMAND_TIMEOUT_SECONDS="${SSM_COMMAND_TIMEOUT_SECONDS:-1800}"
SKIP_TERRAFORM_APPLY="false"
SKIP_DATA_COPY="false"

usage() {
  cat <<'EOF'
Usage: scripts/load_test/start.sh [options]

Options:
  --terraform-dir PATH          Default: environment/load_test
  --var-file PATH               Default: ../../config/secrets/load_test.tfvars
  --prod-db-username-parameter  Default: Terraform output prod_db_username_parameter_name
  --prod-db-password-parameter  Default: Terraform output prod_db_password_parameter_name
  --loadtest-db-username-parameter  Default: Terraform output load_test_db_username_parameter_name
  --loadtest-db-password-parameter  Default: Terraform output load_test_db_password_parameter_name
  --database-name VALUE         Default: Terraform output load_test_db_name
  --migration-prefix VALUE      Default: /solid-connection/loadtest/migration
  --switch-stage-to-loadtest    Restart stage app through SSM with dev,loadtest profiles
  --stage-app-dir PATH          Default: /home/ubuntu/solid-connection-dev
  --stage-compose-file VALUE    Default: docker-compose.dev.yml
  --stage-k6-dir PATH           Default: /home/ubuntu/solid-connection-load-test/k6
  --local-k6-dir PATH           Default: config/load-test/k6
  --ssm-command-timeout-seconds Default: 1800
  --skip-terraform-apply
  --skip-data-copy
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --terraform-dir) TERRAFORM_DIR="$2"; shift 2 ;;
    --var-file) VAR_FILE="$2"; shift 2 ;;
    --prod-db-username-parameter) PROD_DB_USERNAME_PARAMETER="$2"; shift 2 ;;
    --prod-db-password-parameter) PROD_DB_PASSWORD_PARAMETER="$2"; shift 2 ;;
    --loadtest-db-username-parameter) LOADTEST_DB_USERNAME_PARAMETER="$2"; shift 2 ;;
    --loadtest-db-password-parameter) LOADTEST_DB_PASSWORD_PARAMETER="$2"; shift 2 ;;
    --database-name) DATABASE_NAME="$2"; shift 2 ;;
    --migration-prefix) MIGRATION_PARAMETER_PREFIX="$2"; shift 2 ;;
    --switch-stage-to-loadtest) SWITCH_STAGE_TO_LOADTEST="true"; shift ;;
    --stage-app-dir) STAGE_APP_DIR="$2"; shift 2 ;;
    --stage-compose-file) STAGE_COMPOSE_FILE="$2"; shift 2 ;;
    --stage-k6-dir) STAGE_K6_DIR="$2"; shift 2 ;;
    --local-k6-dir) LOCAL_K6_DIR="$2"; shift 2 ;;
    --ssm-command-timeout-seconds) SSM_COMMAND_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --skip-terraform-apply) SKIP_TERRAFORM_APPLY="true"; shift ;;
    --skip-data-copy) SKIP_DATA_COPY="true"; shift ;;
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

file_base64() {
  base64 "$1" | tr -d '\n'
}

sync_stage_k6_files() {
  local instance_id="$1"
  local commands
  commands="$(jq -cn \
    --arg target_dir "$STAGE_K6_DIR" \
    '{ commands: ["set -euo pipefail", "mkdir -p \($target_dir)/script"] }')"

  local relative_path
  for relative_path in \
    "createPost.json" \
    "updatePost.json" \
    "whole-user-flow.js" \
    "set_up_xk6.sh" \
    "script/set-load-test.sh"; do
    local source_path="${LOCAL_K6_DIR}/${relative_path}"
    if [[ ! -f "$source_path" ]]; then
      echo "Missing k6 file: $source_path" >&2
      exit 1
    fi

    commands="$(jq -cn \
      --argjson current "$commands" \
      --arg target "${STAGE_K6_DIR}/${relative_path}" \
      --arg content "$(file_base64 "$source_path")" \
      '$current | .commands += [
        "mkdir -p \"$(dirname \"\($target)\")\"",
        "printf %s \($content | @sh) | base64 -d > \($target | @sh)"
      ]')"
  done

  commands="$(jq -cn \
    --argjson current "$commands" \
    --arg target_dir "$STAGE_K6_DIR" \
    '$current | .commands += [
      "chmod +x \($target_dir)/set_up_xk6.sh \($target_dir)/script/set-load-test.sh",
      "chown -R ubuntu:ubuntu \($target_dir)"
    ]')"

  send_ssm_command "$instance_id" "Sync k6 files to stage EC2" "$commands"
}

delete_temp_parameters() {
  aws ssm delete-parameter --name "$MIGRATION_PARAMETER_PREFIX/prod-db-username" >/dev/null 2>&1 || true
  aws ssm delete-parameter --name "$MIGRATION_PARAMETER_PREFIX/prod-db-password" >/dev/null 2>&1 || true
  aws ssm delete-parameter --name "$MIGRATION_PARAMETER_PREFIX/loadtest-db-username" >/dev/null 2>&1 || true
  aws ssm delete-parameter --name "$MIGRATION_PARAMETER_PREFIX/loadtest-db-password" >/dev/null 2>&1 || true
}

if [[ "$SKIP_TERRAFORM_APPLY" != "true" ]]; then
  terraform -chdir="$TERRAFORM_DIR" init
  terraform -chdir="$TERRAFORM_DIR" apply -auto-approve -var-file="$VAR_FILE"
fi

prod_instance_id="$(tf_output prod_api_instance_id)"
stage_instance_id="$(tf_output stage_api_instance_id)"
stage_public_ip="$(tf_output stage_api_public_ip)"
prod_endpoint="$(tf_output prod_rds_endpoint)"
prod_port="$(tf_output prod_rds_port)"
loadtest_endpoint="$(tf_output load_test_rds_endpoint)"
loadtest_port="$(tf_output load_test_rds_port)"
loadtest_db_name="$(tf_output load_test_db_name)"
tf_prod_db_username_parameter="$(tf_output prod_db_username_parameter_name)"
tf_prod_db_password_parameter="$(tf_output prod_db_password_parameter_name)"
tf_loadtest_db_username_parameter="$(tf_output load_test_db_username_parameter_name)"
tf_loadtest_db_password_parameter="$(tf_output load_test_db_password_parameter_name)"

DATABASE_NAME="${DATABASE_NAME:-$loadtest_db_name}"
PROD_DB_USERNAME_PARAMETER="${PROD_DB_USERNAME_PARAMETER:-$tf_prod_db_username_parameter}"
PROD_DB_PASSWORD_PARAMETER="${PROD_DB_PASSWORD_PARAMETER:-$tf_prod_db_password_parameter}"
LOADTEST_DB_USERNAME_PARAMETER="${LOADTEST_DB_USERNAME_PARAMETER:-$tf_loadtest_db_username_parameter}"
LOADTEST_DB_PASSWORD_PARAMETER="${LOADTEST_DB_PASSWORD_PARAMETER:-$tf_loadtest_db_password_parameter}"

if [[ "$SKIP_DATA_COPY" != "true" ]]; then
  trap delete_temp_parameters EXIT

  prod_db_username="$(aws ssm get-parameter \
    --name "$PROD_DB_USERNAME_PARAMETER" \
    --query "Parameter.Value" \
    --output text)"

  prod_db_password="$(aws ssm get-parameter \
    --name "$PROD_DB_PASSWORD_PARAMETER" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text)"

  loadtest_db_username="$(aws ssm get-parameter \
    --name "$LOADTEST_DB_USERNAME_PARAMETER" \
    --query "Parameter.Value" \
    --output text)"

  loadtest_db_password="$(aws ssm get-parameter \
    --name "$LOADTEST_DB_PASSWORD_PARAMETER" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text)"

  aws ssm put-parameter \
    --name "$MIGRATION_PARAMETER_PREFIX/prod-db-username" \
    --type String \
    --value "$prod_db_username" \
    --overwrite >/dev/null

  aws ssm put-parameter \
    --name "$MIGRATION_PARAMETER_PREFIX/prod-db-password" \
    --type SecureString \
    --value "$prod_db_password" \
    --overwrite >/dev/null

  aws ssm put-parameter \
    --name "$MIGRATION_PARAMETER_PREFIX/loadtest-db-username" \
    --type String \
    --value "$loadtest_db_username" \
    --overwrite >/dev/null

  aws ssm put-parameter \
    --name "$MIGRATION_PARAMETER_PREFIX/loadtest-db-password" \
    --type SecureString \
    --value "$loadtest_db_password" \
    --overwrite >/dev/null

  copy_commands_json="$(jq -cn \
    --arg prefix "$MIGRATION_PARAMETER_PREFIX" \
    --arg prod_endpoint "$prod_endpoint" \
    --arg prod_port "$prod_port" \
    --arg loadtest_endpoint "$loadtest_endpoint" \
    --arg loadtest_port "$loadtest_port" \
    --arg database "$DATABASE_NAME" \
    '{
      commands: [
        "set -euo pipefail",
        "export DEBIAN_FRONTEND=noninteractive",
        "if ! command -v mysqldump >/dev/null 2>&1 || ! command -v mysql >/dev/null 2>&1; then sudo apt-get update && sudo apt-get install -y mysql-client; fi",
        "PROD_USER=$(aws ssm get-parameter --name \($prefix)/prod-db-username --query Parameter.Value --output text)",
        "PROD_PASSWORD=$(aws ssm get-parameter --name \($prefix)/prod-db-password --with-decryption --query Parameter.Value --output text)",
        "LOAD_USER=$(aws ssm get-parameter --name \($prefix)/loadtest-db-username --query Parameter.Value --output text)",
        "LOAD_PASSWORD=$(aws ssm get-parameter --name \($prefix)/loadtest-db-password --with-decryption --query Parameter.Value --output text)",
        "DUMP_FILE=/tmp/solid-connection-loadtest-$(date +%Y%m%d%H%M%S).sql.gz",
        "trap '\''rm -f \"$DUMP_FILE\"'\'' EXIT",
        "MYSQL_PWD=\"$PROD_PASSWORD\" mysqldump --single-transaction --set-gtid-purged=OFF --column-statistics=0 -h \($prod_endpoint) -P \($prod_port) -u \"$PROD_USER\" \($database) | gzip > \"$DUMP_FILE\"",
        "MYSQL_PWD=\"$LOAD_PASSWORD\" mysql -h \($loadtest_endpoint) -P \($loadtest_port) -u \"$LOAD_USER\" -e \"DROP DATABASE IF EXISTS \\\`\($database)\\\`; CREATE DATABASE \\\`\($database)\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\"",
        "gunzip -c \"$DUMP_FILE\" | MYSQL_PWD=\"$LOAD_PASSWORD\" mysql -h \($loadtest_endpoint) -P \($loadtest_port) -u \"$LOAD_USER\" \($database)",
        "rm -f \"$DUMP_FILE\""
      ]
    }')"

  send_ssm_command "$prod_instance_id" "Copy prod RDS data to load test RDS" "$copy_commands_json"
fi

if [[ "$SWITCH_STAGE_TO_LOADTEST" == "true" ]]; then
  sync_stage_k6_files "$stage_instance_id"

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
echo "RDS endpoint: ${loadtest_endpoint}:${loadtest_port}"
echo "Stage instance: ${stage_instance_id}"
echo "Stage public IP: ${stage_public_ip}"
