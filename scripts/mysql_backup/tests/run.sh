#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: $message (expected=$expected actual=$actual)" >&2
    exit 1
  fi
}

test_upload_idempotency() {
  (
    export MYSQL_BACKUP_BUCKET="test-bucket"
    export MYSQL_DATABASE="test_database"
    export AWS_REGION="ap-northeast-2"
    # shellcheck source=../lib/backup-common.sh
    source "$PROJECT_DIR/scripts/mysql_backup/lib/backup-common.sh"

    local expected_checksum
    expected_checksum="$(sha256_file "$PROJECT_DIR/scripts/mysql_backup/README.md")"
    head_object_checksum() { printf '%s' "$expected_checksum"; }
    aws() { echo "Unexpected upload for an existing object." >&2; return 99; }
    upload_file_once "$PROJECT_DIR/scripts/mysql_backup/README.md" "test/key"

    head_object_checksum() { printf '%s' 'different-checksum'; }
    if upload_file_once "$PROJECT_DIR/scripts/mysql_backup/README.md" "test/key" 2>/dev/null; then
      echo "An object with a different checksum must not be overwritten." >&2
      exit 1
    fi
  )
}

write_fake_common() {
  local fixture_dir="$1"

  mkdir -p "$fixture_dir/lib"
  cat >"$fixture_dir/lib/backup-common.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

readonly BACKUP_ROOT="$TEST_BACKUP_ROOT"
readonly STAGING_DIR="$BACKUP_ROOT/staging"
readonly STATE_DIR="$BACKUP_ROOT/state"
readonly MYSQL_DATA_DIR="$TEST_MYSQL_DATA_DIR"
readonly MYSQL_CONTAINER="mysql-server"
readonly MYSQL_BACKUP_BUCKET="${MYSQL_BACKUP_BUCKET:-test-bucket}"
readonly AWS_REGION="${AWS_REGION:-ap-northeast-2}"

require_backup_environment() { :; }
require_commands() { :; }
flock() { return 0; }
aws() { printf '%s' "${TEST_S3_KEYS:-}"; }
date() {
  case "${*: -1}" in
    +%Y%m%dT%H%M%SZ) printf '%s\n' '20260716T030000Z' ;;
    +%Y-%m-%dT%H:%M:%SZ) printf '%s\n' '2026-07-16T03:00:00Z' ;;
    +%Y/%m/%d) printf '%s\n' '2026/07/16' ;;
    +%H%M%S) printf '%s\n' '030000' ;;
    +%s) printf '%s\n' '1784170800' ;;
    *) command date "$@" ;;
  esac
}
stat() {
  if [[ "$1 $2" == '-c %Y' ]]; then
    printf '%s\n' '1784170800'
  elif [[ "$1 $2" == '-c %s' ]]; then
    wc -c <"$3" | tr -d ' '
  else
    command stat "$@"
  fi
}
sha256_file() { sha256sum "$1" | awk '{print $1}'; }
server_uuid() { printf '%s\n' '11111111-2222-3333-4444-555555555555'; }
upload_file_once() {
  printf '%s\n' "$2" >>"$TEST_UPLOAD_LOG"
  if [[ "$2" == */manifest.json || "$2" == *.manifest.json ]]; then
    cp "$1" "$TEST_MANIFEST_CAPTURE"
  fi
  if [[ -n "${TEST_FAIL_MANIFEST_ONCE:-}" && "$2" == */manifest.json && ! -e "$TEST_FAIL_MARKER" ]]; then
    touch "$TEST_FAIL_MARKER"
    return 1
  fi
}
EOF
}

test_binlog_chain() {
  local fixture_dir="$TEST_ROOT/binlog"
  local data_dir="$fixture_dir/mysql"
  local backup_dir="$fixture_dir/backup"
  local upload_log="$fixture_dir/uploads"
  local manifest_capture="$fixture_dir/manifest.json"
  local active_file="$fixture_dir/active-binlog"
  local flush_log="$fixture_dir/flushes"
  local rotation_slot=$((1784170800 / 300))

  write_fake_common "$fixture_dir"
  mkdir -p "$data_dir" "$backup_dir/staging" "$backup_dir/state"
  printf '%s\n' \
    '/var/lib/mysql/binlog.000001' \
    '/var/lib/mysql/binlog.000002' \
    '/var/lib/mysql/binlog.000003' \
    '/var/lib/mysql/binlog.000004' >"$data_dir/binlog.index"
  printf 'one' >"$data_dir/binlog.000001"
  printf 'two' >"$data_dir/binlog.000002"
  printf 'three' >"$data_dir/binlog.000003"
  printf 'four' >"$data_dir/binlog.000004"
  printf '%s\n' 'binlog.000004' >"$active_file"

  cat >>"$fixture_dir/lib/backup-common.sh" <<'EOF'
mysql_query() {
  case "$1" in
    'FLUSH BINARY LOGS;')
      current="$(<"$TEST_ACTIVE_FILE")"
      current_number=$((10#${current##*.}))
      next_binlog="$(printf 'binlog.%06d' "$((current_number + 1))")"
      printf 'closed-%s' "$current" >"$TEST_MYSQL_DATA_DIR/$current"
      printf '/var/lib/mysql/%s\n' "$next_binlog" >>"$TEST_MYSQL_DATA_DIR/binlog.index"
      printf '%s\n' "$next_binlog" >"$TEST_ACTIVE_FILE"
      printf '%s\n' "$next_binlog" >>"$TEST_FLUSH_LOG"
      ;;
    'SHOW BINARY LOG STATUS;') printf '%s 157\n' "$(<"$TEST_ACTIVE_FILE")" ;;
    'SELECT @@server_uuid;') server_uuid ;;
    'SELECT @@log_bin_basename;') printf '%s\n' '/var/lib/mysql/binlog' ;;
    *) echo "Unexpected query: $1" >&2; return 1 ;;
  esac
}
EOF

  TEST_BACKUP_ROOT="$backup_dir" \
  TEST_MYSQL_DATA_DIR="$data_dir" \
  TEST_UPLOAD_LOG="$upload_log" \
  TEST_MANIFEST_CAPTURE="$manifest_capture" \
  TEST_ACTIVE_FILE="$active_file" \
  TEST_FLUSH_LOG="$flush_log" \
  MYSQL_BACKUP_LIB_DIR="$fixture_dir/lib" \
    bash "$PROJECT_DIR/scripts/mysql_backup/bin/mysql-backup-binlog"

  assert_equals "8" "$(wc -l <"$upload_log" | tr -d ' ')" "four closed binlogs and manifests must be uploaded"
  assert_equals \
    "1 test-bucket 11111111-2222-3333-4444-555555555555 binlog.000004 $rotation_slot binlog.000004 binlog.000005" \
    "$(<"$backup_dir/state/binlog-last-uploaded")" \
    "the destination, rotation slot, and last closed binlog must be persisted"
  assert_equals "1" "$(wc -l <"$flush_log" | tr -d ' ')" "the first run must rotate once"

  : >"$upload_log"
  TEST_BACKUP_ROOT="$backup_dir" \
  TEST_MYSQL_DATA_DIR="$data_dir" \
  TEST_UPLOAD_LOG="$upload_log" \
  TEST_MANIFEST_CAPTURE="$manifest_capture" \
  TEST_ACTIVE_FILE="$active_file" \
  TEST_FLUSH_LOG="$flush_log" \
  MYSQL_BACKUP_LIB_DIR="$fixture_dir/lib" \
    bash "$PROJECT_DIR/scripts/mysql_backup/bin/mysql-backup-binlog" >/dev/null
  assert_equals "1" "$(wc -l <"$flush_log" | tr -d ' ')" "a retry in the same five-minute slot must not rotate again"
  assert_equals "0" "$(wc -l <"$upload_log" | tr -d ' ')" "a completed slot retry must not upload another object"

  # FLUSH 직후 상태 완료 기록 전에 종료된 경우에도 active log 변화로 회전 성공을 복구합니다.
  printf '1 test-bucket 11111111-2222-3333-4444-555555555555 binlog.000003 %s binlog.000004 -\n' \
    "$rotation_slot" >"$backup_dir/state/binlog-last-uploaded"
  : >"$upload_log"
  TEST_BACKUP_ROOT="$backup_dir" \
  TEST_MYSQL_DATA_DIR="$data_dir" \
  TEST_UPLOAD_LOG="$upload_log" \
  TEST_MANIFEST_CAPTURE="$manifest_capture" \
  TEST_ACTIVE_FILE="$active_file" \
  TEST_FLUSH_LOG="$flush_log" \
  MYSQL_BACKUP_LIB_DIR="$fixture_dir/lib" \
    bash "$PROJECT_DIR/scripts/mysql_backup/bin/mysql-backup-binlog" >/dev/null
  assert_equals "1" "$(wc -l <"$flush_log" | tr -d ' ')" "a pending state with an advanced active log must not rotate again"
  assert_equals \
    "1 test-bucket 11111111-2222-3333-4444-555555555555 binlog.000004 $rotation_slot binlog.000004 binlog.000005" \
    "$(<"$backup_dir/state/binlog-last-uploaded")" \
    "the pending rotation state must converge after retry"

  rm -f "$backup_dir/state/binlog-last-uploaded"
  : >"$upload_log"
  TEST_BACKUP_ROOT="$backup_dir" \
  TEST_MYSQL_DATA_DIR="$data_dir" \
  TEST_UPLOAD_LOG="$upload_log" \
  TEST_MANIFEST_CAPTURE="$manifest_capture" \
  TEST_ACTIVE_FILE="$active_file" \
  TEST_FLUSH_LOG="$flush_log" \
  TEST_S3_KEYS='binlog/2026/07/16/025500-11111111-2222-3333-4444-555555555555-binlog.000002.manifest.json' \
  MYSQL_BACKUP_LIB_DIR="$fixture_dir/lib" \
    bash "$PROJECT_DIR/scripts/mysql_backup/bin/mysql-backup-binlog" >/dev/null
  assert_equals "6" "$(wc -l <"$upload_log" | tr -d ' ')" "S3 state recovery must skip older binlogs and upload the remaining closed chain"

  # 동일 서버에서 목적지가 바뀌면 이전 버킷의 last_uploaded를 신뢰하지 않습니다.
  printf '%s\n' 'binlog.000006' >"$active_file"
  printf '%s\n' \
    '/var/lib/mysql/binlog.000001' \
    '/var/lib/mysql/binlog.000002' \
    '/var/lib/mysql/binlog.000003' \
    '/var/lib/mysql/binlog.000004' \
    '/var/lib/mysql/binlog.000005' \
    '/var/lib/mysql/binlog.000006' >"$data_dir/binlog.index"
  printf 'five' >"$data_dir/binlog.000005"
  printf '1 old-bucket 11111111-2222-3333-4444-555555555555 binlog.000005 %s binlog.000005 binlog.000006\n' \
    "$rotation_slot" >"$backup_dir/state/binlog-last-uploaded"
  : >"$upload_log"
  TEST_BACKUP_ROOT="$backup_dir" \
  TEST_MYSQL_DATA_DIR="$data_dir" \
  TEST_UPLOAD_LOG="$upload_log" \
  TEST_MANIFEST_CAPTURE="$manifest_capture" \
  TEST_ACTIVE_FILE="$active_file" \
  TEST_FLUSH_LOG="$flush_log" \
  MYSQL_BACKUP_BUCKET="new-bucket" \
  MYSQL_BACKUP_LIB_DIR="$fixture_dir/lib" \
    bash "$PROJECT_DIR/scripts/mysql_backup/bin/mysql-backup-binlog" >/dev/null
  [[ "$(<"$backup_dir/state/binlog-last-uploaded")" == "1 new-bucket "* ]]
  assert_equals "12" "$(wc -l <"$upload_log" | tr -d ' ')" "a destination change must rebuild the available closed chain in the new bucket"

  printf '%s\n' \
    '/var/lib/mysql/binlog.000001' \
    '/var/lib/mysql/binlog.000003' \
    '/var/lib/mysql/binlog.000004' >"$data_dir/binlog.index"
  printf '%s\n' 'binlog.000004' >"$active_file"
  printf '1 test-bucket 11111111-2222-3333-4444-555555555555 binlog.000001 %s binlog.000003 binlog.000004\n' \
    "$rotation_slot" >"$backup_dir/state/binlog-last-uploaded"

  if TEST_BACKUP_ROOT="$backup_dir" \
    TEST_MYSQL_DATA_DIR="$data_dir" \
    TEST_UPLOAD_LOG="$upload_log" \
    TEST_MANIFEST_CAPTURE="$manifest_capture" \
    TEST_ACTIVE_FILE="$active_file" \
    TEST_FLUSH_LOG="$flush_log" \
    MYSQL_BACKUP_LIB_DIR="$fixture_dir/lib" \
      bash "$PROJECT_DIR/scripts/mysql_backup/bin/mysql-backup-binlog" >/dev/null 2>&1; then
    echo "A missing binlog in the chain must fail the backup." >&2
    exit 1
  fi
}

test_dump_retry_manifest() {
  local fixture_dir="$TEST_ROOT/dump"
  local backup_dir="$fixture_dir/backup"
  local upload_log="$fixture_dir/uploads"
  local manifest_capture="$fixture_dir/manifest.json"
  local first_manifest="$fixture_dir/first-manifest.json"
  local first_attempt_log="$fixture_dir/first-attempt.log"

  write_fake_common "$fixture_dir"
  mkdir -p "$backup_dir/staging" "$backup_dir/state"
  cat >>"$fixture_dir/lib/backup-common.sh" <<'EOF'
docker() {
  printf '%s\n' "-- CHANGE REPLICATION SOURCE TO SOURCE_LOG_FILE='binlog.000003', SOURCE_LOG_POS=157;"
  printf '%s\n' 'CREATE TABLE example (id bigint);'
}
EOF

  if TEST_BACKUP_ROOT="$backup_dir" \
    TEST_MYSQL_DATA_DIR="$fixture_dir/mysql" \
    TEST_UPLOAD_LOG="$upload_log" \
    TEST_MANIFEST_CAPTURE="$manifest_capture" \
    MYSQL_DATABASE="test_database" \
    TEST_FAIL_MANIFEST_ONCE=1 \
    TEST_FAIL_MARKER="$fixture_dir/failed-once" \
    MYSQL_BACKUP_LIB_DIR="$fixture_dir/lib" \
      bash "$PROJECT_DIR/scripts/mysql_backup/bin/mysql-backup-dump" >"$first_attempt_log" 2>&1; then
    echo "The first dump attempt must simulate a manifest upload failure." >&2
    exit 1
  fi
  if [[ ! -f "$manifest_capture" ]]; then
    cat "$first_attempt_log" >&2
    echo "The failed attempt did not reach the manifest upload." >&2
    exit 1
  fi
  assert_equals \
    "20260716T030000Z" \
    "$(<"$backup_dir/state/dump-current")" \
    "a failed dump attempt must retain a valid retry job id"
  [[ ! -e "$backup_dir/state/dump-current.tmp" ]]
  cp "$manifest_capture" "$first_manifest"
  sleep 1

  TEST_BACKUP_ROOT="$backup_dir" \
  TEST_MYSQL_DATA_DIR="$fixture_dir/mysql" \
  TEST_UPLOAD_LOG="$upload_log" \
  TEST_MANIFEST_CAPTURE="$manifest_capture" \
  MYSQL_DATABASE="test_database" \
  TEST_FAIL_MANIFEST_ONCE=1 \
  TEST_FAIL_MARKER="$fixture_dir/failed-once" \
  MYSQL_BACKUP_LIB_DIR="$fixture_dir/lib" \
    bash "$PROJECT_DIR/scripts/mysql_backup/bin/mysql-backup-dump" >/dev/null

  cmp "$first_manifest" "$manifest_capture"
  [[ ! -e "$backup_dir/state/dump-current" ]]
}

test_upload_idempotency
test_binlog_chain
test_dump_retry_manifest
echo "All MySQL backup tests passed."
