#!/usr/bin/env bash
set -euo pipefail

TERRAFORM_DIR="environment/load_test"
VAR_FILE="../../config/secrets/load_test.tfvars"
DATABASE_NAME="solid_connection"
MIGRATION_PARAMETER_PREFIX="/solid-connection/loadtest/migration"
PROD_DB_USERNAME_PARAMETER="/solid-connection/prod/spring.datasource.username"
PROD_DB_PASSWORD_PARAMETER="/solid-connection/prod/spring.datasource.password"
LOADTEST_DB_USERNAME_PARAMETER="/solid-connection/loadtest/spring.datasource.username"
LOADTEST_DB_PASSWORD_PARAMETER="/solid-connection/loadtest/spring.datasource.password"
SWITCH_STAGE_TO_LOADTEST="false"
STAGE_APP_DIR="/home/ubuntu/solid-connection-dev"
STAGE_COMPOSE_FILE="docker-compose.dev.yml"
SKIP_TERRAFORM_APPLY="false"
SKIP_DATA_COPY="false"

usage() {
  cat <<'EOF'
Usage: scripts/load_test/start.sh [options]

Options:
  --terraform-dir PATH          Default: environment/load_test
  --var-file PATH               Default: ../../config/secrets/load_test.tfvars
  --prod-db-username-parameter  Default: /solid-connection/prod/spring.datasource.username
  --prod-db-password-parameter  Default: /solid-connection/prod/spring.datasource.password
  --loadtest-db-username-parameter  Default: /solid-connection/loadtest/spring.datasource.username
  --loadtest-db-password-parameter  Default: /solid-connection/loadtest/spring.datasource.password
  --database-name VALUE         Default: solid_connection
  --migration-prefix VALUE      Default: /solid-connection/loadtest/migration
  --switch-stage-to-loadtest    Restart stage app through SSM with dev,loadtest profiles
  --stage-app-dir PATH          Default: /home/ubuntu/solid-connection-dev
  --stage-compose-file VALUE    Default: docker-compose.dev.yml
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
        "MYSQL_PWD=\"$PROD_PASSWORD\" mysqldump --single-transaction --set-gtid-purged=OFF --column-statistics=0 -h \($prod_endpoint) -P \($prod_port) -u \"$PROD_USER\" \($database) | gzip > \"$DUMP_FILE\"",
        "MYSQL_PWD=\"$LOAD_PASSWORD\" mysql -h \($loadtest_endpoint) -P \($loadtest_port) -u \"$LOAD_USER\" -e \"DROP DATABASE IF EXISTS \\\`\($database)\\\`; CREATE DATABASE \\\`\($database)\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\"",
        "gunzip -c \"$DUMP_FILE\" | MYSQL_PWD=\"$LOAD_PASSWORD\" mysql -h \($loadtest_endpoint) -P \($loadtest_port) -u \"$LOAD_USER\" \($database)",
        "rm -f \"$DUMP_FILE\""
      ]
    }')"

  send_ssm_command "$prod_instance_id" "Copy prod RDS data to load test RDS" "$copy_commands_json"
fi

echo "Load test environment is ready."
echo "RDS endpoint: ${loadtest_endpoint}:${loadtest_port}"
echo "Stage instance: ${stage_instance_id}"
echo "Stage public IP: ${stage_public_ip}"
