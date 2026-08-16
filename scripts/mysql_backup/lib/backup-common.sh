#!/usr/bin/env bash
set -Eeuo pipefail

readonly BACKUP_ROOT="${MYSQL_BACKUP_ROOT:-/mnt/mysql-data/mysql-backup}"
readonly STAGING_DIR="$BACKUP_ROOT/staging"
readonly STATE_DIR="$BACKUP_ROOT/state"
readonly MYSQL_DATA_DIR="${MYSQL_DATA_DIR:-/mnt/mysql-data/mysql}"
readonly MYSQL_CONTAINER="${MYSQL_CONTAINER:-mysql-server}"
readonly DUMP_SPACE_RESERVE_BYTES=268435456

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
