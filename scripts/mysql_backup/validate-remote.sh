#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONFIG_FILE="/etc/solid-connection/mysql-backup.env"
readonly VALIDATE_BIN="/usr/local/libexec/solid-connection/mysql-backup-validate"

if ((EUID != 0)); then
  echo "Remote validation must run as root." >&2
  exit 1
fi

if [[ -x "$VALIDATE_BIN" && -f "$CONFIG_FILE" ]]; then
  unset MYSQL_BACKUP_BUCKET MYSQL_DATABASE AWS_REGION ALARM_API_HOST ALARM_API_PORTS ALARM_API_HEALTH_PORTS ALARM_API_TOKEN
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    case "$key" in
      MYSQL_BACKUP_BUCKET|MYSQL_DATABASE|AWS_REGION|ALARM_API_HOST|ALARM_API_PORTS|ALARM_API_HEALTH_PORTS|ALARM_API_TOKEN)
        printf -v "$key" '%s' "$value"
        export "$key"
        ;;
      *)
        echo "Unsupported backup configuration key: $key" >&2
        exit 1
        ;;
    esac
  done <"$CONFIG_FILE"
  # 이 경로는 설치된 값 그대로 검증하므로, 새 항목이 추가된 뒤 재설치하지 않은 환경을 구분해 알려줍니다.
  if [[ -z "${ALARM_API_HEALTH_PORTS:-}" ]]; then
    echo "ALARM_API_HEALTH_PORTS is missing in $CONFIG_FILE." >&2
    echo "Run the deploy workflow with the install action to refresh the environment file." >&2
    exit 1
  fi
  "$VALIDATE_BIN"
  systemctl is-enabled --quiet mysql-backup-binlog.timer mysql-backup-dump.timer
  systemctl is-active --quiet mysql-backup-binlog.timer mysql-backup-dump.timer
  systemctl list-timers --no-pager --all 'mysql-backup-*'
  exit 0
fi

for command_name in aws curl docker flock gzip sha256sum; do
  command -v "$command_name" >/dev/null || {
    echo "Required command is not installed: $command_name" >&2
    exit 1
  }
done
: "${MYSQL_BACKUP_BUCKET:?MYSQL_BACKUP_BUCKET is required for pre-installation validation}"
: "${MYSQL_DATABASE:?MYSQL_DATABASE is required for pre-installation validation}"
: "${AWS_REGION:?AWS_REGION is required for pre-installation validation}"
: "${ALARM_API_HOST:?ALARM_API_HOST is required for pre-installation validation}"
: "${ALARM_API_PORTS:?ALARM_API_PORTS is required for pre-installation validation}"
: "${ALARM_API_HEALTH_PORTS:?ALARM_API_HEALTH_PORTS is required for pre-installation validation}"
: "${ALARM_API_TOKEN:?ALARM_API_TOKEN is required for pre-installation validation}"
# 설치 전에는 공용 라이브러리가 없으므로 같은 범위 검증을 여기에 둡니다.
# 8진수로 해석되지 않도록 10# 을 붙여 비교합니다.
if [[ ! "$ALARM_API_HOST" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo "Invalid alarm api host: $ALARM_API_HOST" >&2
  exit 1
fi
for alarm_host_octet in ${ALARM_API_HOST//./ }; do
  if ((10#$alarm_host_octet > 255)); then
    echo "Invalid alarm api host: $ALARM_API_HOST" >&2
    exit 1
  fi
done
for alarm_port_list in "$ALARM_API_PORTS" "$ALARM_API_HEALTH_PORTS"; do
  if [[ ! "$alarm_port_list" =~ ^[0-9]+( [0-9]+)*$ ]]; then
    echo "Invalid alarm api ports: $alarm_port_list" >&2
    exit 1
  fi
  for alarm_port in $alarm_port_list; do
    if ((10#$alarm_port < 1 || 10#$alarm_port > 65535)); then
      echo "Invalid alarm api ports: $alarm_port_list" >&2
      exit 1
    fi
  done
done
if [[ ! "$MYSQL_BACKUP_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
  echo "Invalid S3 bucket name." >&2
  exit 1
fi
if [[ ! "$MYSQL_DATABASE" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "Invalid MySQL database name." >&2
  exit 1
fi
mountpoint -q /mnt/mysql-data
docker inspect mysql-server >/dev/null
mysql_settings="$(docker exec mysql-server sh -lc '
  MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot --batch --skip-column-names -e "
    SELECT @@log_bin, @@binlog_format, @@server_id,
           @@sync_binlog, @@innodb_flush_log_at_trx_commit;
  "
')"
read -r log_bin binlog_format server_id sync_binlog flush_policy <<<"$mysql_settings"
if [[ "$log_bin" != "1" || "$binlog_format" != "ROW" || "$server_id" == "0" ]]; then
  echo "MySQL binlog configuration is not suitable for backup." >&2
  exit 1
fi
if [[ "$sync_binlog" != "1" || "$flush_policy" != "1" ]]; then
  echo "MySQL durability configuration is not sync_binlog=1 and innodb_flush_log_at_trx_commit=1." >&2
  exit 1
fi
schema_exists="$(docker exec mysql-server sh -lc \
  'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot --batch --skip-column-names -e "$1"' \
  sh "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = '$MYSQL_DATABASE';")"
if [[ "$schema_exists" != "1" ]]; then
  echo "MySQL backup database does not exist: $MYSQL_DATABASE" >&2
  exit 1
fi
database_bytes="$(docker exec mysql-server sh -lc \
  'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot --batch --skip-column-names -e "$1"' \
  sh "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = '$MYSQL_DATABASE';")"
available_bytes="$(df --output=avail -B1 /mnt/mysql-data | tail -1 | tr -d ' ')"
if [[ ! "$database_bytes" =~ ^[0-9]+$ || ! "$available_bytes" =~ ^[0-9]+$ ]]; then
  echo "Failed to calculate database size or available backup space." >&2
  exit 1
fi
required_bytes=$((database_bytes * 2 + 268435456))
if ((available_bytes < required_bytes)); then
  echo "Insufficient backup staging space: available=$available_bytes required=$required_bytes" >&2
  exit 1
fi
aws s3api head-bucket --bucket "$MYSQL_BACKUP_BUCKET" --region "$AWS_REGION" >/dev/null

# 설치 전에는 공용 라이브러리가 없으므로 lib/backup-common.sh 의 verify_alarm_endpoint 와 같은 검증을 여기에 둡니다.
# 알림 경로와 판정 기준을 바꿀 때는 두 곳을 함께 고쳐야 합니다.
# 비활성 슬롯은 내려가 있으므로 설정된 포트 중 하나라도 응답하면 통과합니다.
alarm_api_healthy=false
for alarm_health_port in ${ALARM_API_HEALTH_PORTS}; do
  alarm_health_response="$(curl -fsS --max-time 3 "http://${ALARM_API_HOST}:${alarm_health_port}/actuator/health" 2>/dev/null)" || alarm_health_response=""
  case "$alarm_health_response" in
    *'"status":"UP"'*)
      alarm_api_healthy=true
      echo "Api server is healthy on management port $alarm_health_port."
      break
      ;;
  esac
done
if [[ "$alarm_api_healthy" != "true" ]]; then
  echo "No api server responded as UP on the management ports: $ALARM_API_HEALTH_PORTS" >&2
  echo "Check whether the api server is running and whether the management port convention has changed." >&2
  exit 1
fi

alarm_endpoint_deployed=false
for alarm_port in ${ALARM_API_PORTS}; do
  alarm_status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
    -X POST "http://${ALARM_API_HOST}:${alarm_port}/internal/alarms/db-backup" \
    -H "Content-Type: application/json" \
    -H "X-Internal-Alarm-Token: invalid-token-for-validation" \
    -d '{"type":"DUMP_FAILED","instanceId":"validation","occurredAt":"2026-01-01T00:00:00Z"}' 2>/dev/null)" \
    || alarm_status="000"
  if [[ "$alarm_status" == "401" ]]; then
    alarm_endpoint_deployed=true
    echo "Alarm endpoint is deployed on app port $alarm_port."
    break
  fi
done
if [[ "$alarm_endpoint_deployed" != "true" ]]; then
  echo "The alarm endpoint did not reject an invalid token on any app port: $ALARM_API_PORTS" >&2
  echo "The endpoint may not be deployed on the running api server yet." >&2
  exit 1
fi

df -h / /mnt/mysql-data
echo "Pre-installation validation succeeded."
