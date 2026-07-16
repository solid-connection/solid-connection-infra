#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONFIG_FILE="/etc/solid-connection/mysql-backup.env"
readonly VALIDATE_BIN="/usr/local/libexec/solid-connection/mysql-backup-validate"

if ((EUID != 0)); then
  echo "Remote validation must run as root." >&2
  exit 1
fi

if [[ -x "$VALIDATE_BIN" && -f "$CONFIG_FILE" ]]; then
  "$VALIDATE_BIN"
  systemctl is-enabled --quiet mysql-backup-binlog.timer mysql-backup-dump.timer
  systemctl is-active --quiet mysql-backup-binlog.timer mysql-backup-dump.timer
  systemctl list-timers --no-pager --all 'mysql-backup-*'
  exit 0
fi

for command_name in aws docker flock gzip sha256sum; do
  command -v "$command_name" >/dev/null || {
    echo "Required command is not installed: $command_name" >&2
    exit 1
  }
done
: "${MYSQL_BACKUP_BUCKET:?MYSQL_BACKUP_BUCKET is required for pre-installation validation}"
: "${MYSQL_DATABASE:?MYSQL_DATABASE is required for pre-installation validation}"
: "${AWS_REGION:?AWS_REGION is required for pre-installation validation}"
mountpoint -q /mnt/mysql-data
docker inspect mysql-server >/dev/null
docker exec mysql-server sh -lc '
  MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot --batch --skip-column-names -e "
    SELECT @@log_bin, @@binlog_format, @@server_id,
           @@sync_binlog, @@innodb_flush_log_at_trx_commit;
  "
'
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
df -h / /mnt/mysql-data
echo "Pre-installation validation succeeded."
