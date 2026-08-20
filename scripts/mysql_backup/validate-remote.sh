#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONFIG_FILE="/etc/solid-connection/mysql-backup.env"
readonly VALIDATE_BIN="/usr/local/libexec/solid-connection/mysql-backup-validate"

if ((EUID != 0)); then
  echo "Remote validation must run as root." >&2
  exit 1
fi

if [[ -x "$VALIDATE_BIN" && -f "$CONFIG_FILE" ]]; then
  unset MYSQL_BACKUP_BUCKET MYSQL_DATABASE AWS_REGION ALARM_API_HOST ALARM_API_PORTS ALARM_API_TOKEN
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    case "$key" in
      MYSQL_BACKUP_BUCKET|MYSQL_DATABASE|AWS_REGION|ALARM_API_HOST|ALARM_API_PORTS|ALARM_API_TOKEN)
        printf -v "$key" '%s' "$value"
        export "$key"
        ;;
      *)
        echo "Unsupported backup configuration key: $key" >&2
        exit 1
        ;;
    esac
  done <"$CONFIG_FILE"
  "$VALIDATE_BIN"
  systemctl is-enabled --quiet mysql-backup-binlog.timer mysql-backup-dump.timer
  systemctl is-active --quiet mysql-backup-binlog.timer mysql-backup-dump.timer
  systemctl list-timers --no-pager --all 'mysql-backup-*'
  exit 0
fi

for command_name in aws curl docker flock gzip sha256sum timeout; do
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
: "${ALARM_API_TOKEN:?ALARM_API_TOKEN is required for pre-installation validation}"
if [[ ! "$ALARM_API_HOST" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo "Invalid alarm api host." >&2
  exit 1
fi
if [[ ! "$ALARM_API_PORTS" =~ ^[0-9]+( [0-9]+)*$ ]]; then
  echo "Invalid alarm api ports." >&2
  exit 1
fi
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

# 비활성 슬롯은 내려가 있으므로 설정된 포트 중 하나라도 열려 있으면 통과합니다.
alarm_endpoint_reachable=false
for alarm_port in ${ALARM_API_PORTS}; do
  if timeout 3 bash -c "exec 3<>/dev/tcp/${ALARM_API_HOST}/${alarm_port}" 2>/dev/null; then
    alarm_endpoint_reachable=true
    echo "Alarm api is reachable on port $alarm_port."
    break
  fi
done
if [[ "$alarm_endpoint_reachable" != "true" ]]; then
  echo "Alarm api is not reachable on any of the configured ports: $ALARM_API_PORTS" >&2
  exit 1
fi

df -h / /mnt/mysql-data
echo "Pre-installation validation succeeded."
