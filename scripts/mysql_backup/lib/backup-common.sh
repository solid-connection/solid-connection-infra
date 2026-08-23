#!/usr/bin/env bash
set -Eeuo pipefail

readonly BACKUP_ROOT="${MYSQL_BACKUP_ROOT:-/mnt/mysql-data/mysql-backup}"
readonly STAGING_DIR="$BACKUP_ROOT/staging"
readonly STATE_DIR="$BACKUP_ROOT/state"
readonly MYSQL_DATA_DIR="${MYSQL_DATA_DIR:-/mnt/mysql-data/mysql}"
readonly MYSQL_CONTAINER="${MYSQL_CONTAINER:-mysql-server}"
readonly DUMP_SPACE_RESERVE_BYTES=268435456
readonly ALARM_PATH="/internal/alarms/db-backup"
readonly ALARM_TIMEOUT_SECONDS=5
readonly ALARM_RETRY_COUNT=2
readonly ALARM_DETAIL_MAX_LENGTH=1000

# 같은 실패로 알림이 두 번 나가지 않도록 전송 여부를 기록합니다.
alarm_sent=false

require_backup_environment() {
  : "${MYSQL_BACKUP_BUCKET:?MYSQL_BACKUP_BUCKET is required}"
  : "${MYSQL_DATABASE:?MYSQL_DATABASE is required}"
  : "${AWS_REGION:?AWS_REGION is required}"

  if [[ ! "$MYSQL_BACKUP_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
    echo "Invalid S3 bucket name." >&2
    return 1
  fi
  if [[ ! "$MYSQL_DATABASE" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "Invalid MySQL database name." >&2
    return 1
  fi

}

require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null || {
      echo "Required command is not installed: $command_name" >&2
      return 1
    }
  done
}

mysql_query() {
  local query="$1"
  docker exec "$MYSQL_CONTAINER" sh -lc \
    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot --batch --skip-column-names -e "$1"' \
    sh "$query"
}

server_uuid() {
  mysql_query 'SELECT @@server_uuid;'
}

require_dump_staging_space() {
  local database_bytes
  local available_bytes
  local required_bytes

  database_bytes="$(mysql_query "
SELECT COALESCE(SUM(data_length + index_length), 0)
FROM information_schema.tables
WHERE table_schema = '$MYSQL_DATABASE';
")"
  available_bytes="$(df --output=avail -B1 "$BACKUP_ROOT" | tail -1 | tr -d ' ')"

  if [[ ! "$database_bytes" =~ ^[0-9]+$ || ! "$available_bytes" =~ ^[0-9]+$ ]]; then
    echo "Failed to calculate database size or available backup space." >&2
    return 1
  fi
  required_bytes=$((database_bytes * 2 + DUMP_SPACE_RESERVE_BYTES))

  if ((available_bytes < required_bytes)); then
    echo "Insufficient backup staging space: available=$available_bytes required=$required_bytes" >&2
    return 1
  fi

  printf '%s %s %s\n' "$database_bytes" "$available_bytes" "$required_bytes"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

head_object_checksum() {
  local object_key="$1"
  local error_file
  local checksum

  error_file="$(mktemp)"
  if checksum="$(aws s3api head-object \
    --bucket "$MYSQL_BACKUP_BUCKET" \
    --key "$object_key" \
    --region "$AWS_REGION" \
    --query 'Metadata.sha256' \
    --output text 2>"$error_file")"; then
    rm -f "$error_file"
    printf '%s' "$checksum"
    return 0
  fi

  if grep -Eq '(404|Not Found|NoSuchKey)' "$error_file"; then
    rm -f "$error_file"
    return 1
  fi

  cat "$error_file" >&2
  rm -f "$error_file"
  return 2
}

upload_file_once() {
  local local_file="$1"
  local object_key="$2"
  local checksum
  local remote_checksum
  local head_status

  checksum="$(sha256_file "$local_file")"
  if remote_checksum="$(head_object_checksum "$object_key")"; then
    if [[ "$remote_checksum" != "$checksum" ]]; then
      echo "S3 object already exists with a different checksum: $object_key" >&2
      return 1
    fi
    echo "Skipping an object that is already uploaded: $object_key"
    return 0
  else
    head_status=$?
    if ((head_status != 1)); then
      return "$head_status"
    fi
  fi

  aws s3 cp "$local_file" "s3://$MYSQL_BACKUP_BUCKET/$object_key" \
    --region "$AWS_REGION" \
    --only-show-errors \
    --no-progress \
    --metadata "sha256=$checksum"
}

require_alarm_environment() {
  : "${ALARM_API_HOST:?ALARM_API_HOST is required}"
  : "${ALARM_API_PORTS:?ALARM_API_PORTS is required}"
  : "${ALARM_API_HEALTH_PORTS:?ALARM_API_HEALTH_PORTS is required}"
  : "${ALARM_API_TOKEN:?ALARM_API_TOKEN is required}"

  validate_alarm_target "$ALARM_API_HOST" "$ALARM_API_PORTS"
  validate_alarm_target "$ALARM_API_HOST" "$ALARM_API_HEALTH_PORTS"
}

# 8진수로 해석되지 않도록 10# 을 붙여 비교합니다.
validate_alarm_target() {
  local host="$1"
  local ports="$2"
  local octet
  local port

  if [[ ! "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "Invalid alarm api host: $host" >&2
    return 1
  fi
  for octet in ${host//./ }; do
    if ((10#$octet > 255)); then
      echo "Invalid alarm api host: $host" >&2
      return 1
    fi
  done

  if [[ ! "$ports" =~ ^[0-9]+( [0-9]+)*$ ]]; then
    echo "Invalid alarm api ports: $ports" >&2
    return 1
  fi
  for port in $ports; do
    if ((10#$port < 1 || 10#$port > 65535)); then
      echo "Invalid alarm api ports: $ports" >&2
      return 1
    fi
  done
}

instance_id() {
  local metadata_token

  metadata_token="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
    --max-time 2 2>/dev/null)" || return 1
  curl -fsS -H "X-aws-ec2-metadata-token: $metadata_token" \
    "http://169.254.169.254/latest/meta-data/instance-id" \
    --max-time 2 2>/dev/null
}

# sed 의 N 명령은 GNU 와 BSD 동작이 달라 한 줄 입력에서 결과가 사라지므로 bash 치환만 사용합니다.
json_escape() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\t'/ }"
  value="${value//$'\n'/\\n}"
  printf '%s' "$value"
}

# 활성 슬롯을 알 수 없으므로 blue, green 순서로 시도하고 먼저 응답한 쪽으로 보냅니다.
# 알림 전송 실패가 백업 자체를 실패시키지 않도록 항상 0으로 종료합니다.
send_backup_alarm() {
  local alarm_type="$1"
  local detail="$2"
  local target_instance_id
  local header_config
  local payload
  local port

  if [[ -z "${ALARM_API_HOST:-}" || -z "${ALARM_API_TOKEN:-}" ]]; then
    echo "Alarm target is not configured; skipping the backup alarm." >&2
    return 0
  fi

  target_instance_id="$(instance_id)" || target_instance_id="unknown"
  payload="$(printf '{"type":"%s","instanceId":"%s","occurredAt":"%s","detail":"%s"}' \
    "$alarm_type" \
    "$target_instance_id" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(json_escape "${detail:0:ALARM_DETAIL_MAX_LENGTH}")")"

  # 토큰이 프로세스 목록에 남지 않도록 헤더를 설정 파일로 전달합니다.
  # 준비 단계가 실패해도 백업 자체는 계속되어야 하므로 항상 0 으로 돌아갑니다.
  if ! header_config="$(mktemp 2>/dev/null)"; then
    echo "Failed to create a temporary file for the backup alarm request." >&2
    return 0
  fi
  if ! chmod 600 "$header_config" 2>/dev/null \
    || ! printf 'header = "X-Internal-Alarm-Token: %s"\n' "$ALARM_API_TOKEN" >"$header_config" 2>/dev/null; then
    echo "Failed to prepare the backup alarm request." >&2
    rm -f "$header_config"
    return 0
  fi

  for port in ${ALARM_API_PORTS}; do
    if curl -fsS \
      --config "$header_config" \
      --max-time "$ALARM_TIMEOUT_SECONDS" \
      --retry "$ALARM_RETRY_COUNT" \
      --retry-delay 3 \
      -X POST "http://${ALARM_API_HOST}:${port}${ALARM_PATH}" \
      -H "Content-Type: application/json" \
      -d "$payload" >/dev/null 2>&1; then
      rm -f "$header_config"
      alarm_sent=true
      echo "Sent a backup alarm: type=$alarm_type port=$port"
      return 0
    fi
  done

  rm -f "$header_config"
  echo "Failed to send a backup alarm: type=$alarm_type" >&2
  return 0
}

fail_with_alarm() {
  local alarm_type="$1"
  local detail="$2"

  echo "$detail" >&2
  send_backup_alarm "$alarm_type" "$detail"
  exit 1
}

# 명시적으로 처리하지 않은 실패도 알리기 위해 스크립트 종료 시점에 한 번 더 확인합니다.
alarm_on_unexpected_failure() {
  local exit_code=$?
  local default_alarm_type="$1"

  if ((exit_code != 0)) && [[ "$alarm_sent" != "true" ]]; then
    send_backup_alarm "$default_alarm_type" "unexpected failure with exit code $exit_code"
  fi
  return 0
}

# 스크립트는 돌고 있지만 업로드가 계속 실패해 마지막 성공이 오래된 경우를 알립니다.
# EC2 나 타이머 자체가 멈춘 경우는 이 방식으로 감지할 수 없어 외부 모니터링이 필요합니다.
alarm_if_upload_delayed() {
  local success_file="$1"
  local threshold_seconds="$2"
  local last_success_epoch
  local elapsed_seconds

  [[ -s "$success_file" ]] || return 0
  last_success_epoch="$(<"$success_file")"
  [[ "$last_success_epoch" =~ ^[0-9]+$ ]] || return 0

  elapsed_seconds=$(( $(date -u +%s) - last_success_epoch ))
  if ((elapsed_seconds > threshold_seconds)); then
    send_backup_alarm BINLOG_UPLOAD_DELAYED \
      "the last successful binlog upload was $elapsed_seconds seconds ago"
    # 지연은 실패가 아니므로, 이번 실행이 실제로 실패하면 다시 알릴 수 있도록 되돌립니다.
    alarm_sent=false
  fi
}

# 알림 경로가 실제로 동작하는지 확인합니다.
# - management 포트의 health 로 api 서버가 기동했는지 확인합니다. tcp 연결만으로는 앱 기동 여부를 알 수 없습니다.
# - 잘못된 토큰으로 알림 경로를 호출해 401 이 오는지 확인합니다. 경로가 배포되지 않았다면 404 가 옵니다.
# - 토큰 값이 실제로 맞는지는 알림을 발생시키지 않고 확인할 수 없어 검증 대상에서 제외합니다.
verify_alarm_endpoint() {
  local port
  local health_response
  local status
  local is_healthy=false
  local is_endpoint_deployed=false

  for port in ${ALARM_API_HEALTH_PORTS}; do
    health_response="$(curl -fsS --max-time 3 "http://${ALARM_API_HOST}:${port}/actuator/health" 2>/dev/null)" || health_response=""
    case "$health_response" in
      *'"status":"UP"'*)
        is_healthy=true
        echo "Api server is healthy on management port $port."
        break
        ;;
    esac
  done
  if [[ "$is_healthy" != "true" ]]; then
    echo "No api server responded as UP on the management ports: $ALARM_API_HEALTH_PORTS" >&2
    echo "Check whether the api server is running and whether the management port convention has changed." >&2
    return 1
  fi

  for port in ${ALARM_API_PORTS}; do
    status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
      -X POST "http://${ALARM_API_HOST}:${port}${ALARM_PATH}" \
      -H "Content-Type: application/json" \
      -H "X-Internal-Alarm-Token: invalid-token-for-validation" \
      -d '{"type":"DUMP_FAILED","instanceId":"validation","occurredAt":"2026-01-01T00:00:00Z"}' 2>/dev/null)" \
      || status="000"
    if [[ "$status" == "401" ]]; then
      is_endpoint_deployed=true
      echo "Alarm endpoint is deployed on app port $port."
      break
    fi
  done
  if [[ "$is_endpoint_deployed" != "true" ]]; then
    echo "The alarm endpoint did not reject an invalid token on any app port: $ALARM_API_PORTS" >&2
    echo "The endpoint may not be deployed on the running api server yet." >&2
    return 1
  fi
}
