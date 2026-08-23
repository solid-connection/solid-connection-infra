#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly PROJECT_DIR
TEST_ROOT="$(mktemp -d)"
readonly TEST_ROOT
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

test_dump_space_calculation() {
  (
    export MYSQL_BACKUP_BUCKET="test-bucket"
    export MYSQL_DATABASE="test_database"
    export AWS_REGION="ap-northeast-2"
    export MYSQL_BACKUP_ROOT="$TEST_ROOT/space-check"
    # shellcheck source=../lib/backup-common.sh
    source "$PROJECT_DIR/scripts/mysql_backup/lib/backup-common.sh"

    mysql_query() { printf '%s\n' '1024'; }
    df() { printf 'Avail\n%s\n' "$TEST_AVAILABLE_BYTES"; }

    TEST_AVAILABLE_BYTES=268437504
    assert_equals \
      "1024 268437504 268437504" \
      "$(require_dump_staging_space)" \
      "the staging-space calculation must include twice the database size and the reserve"

    TEST_AVAILABLE_BYTES=268437503
    if require_dump_staging_space >/dev/null 2>&1; then
      echo "Insufficient dump staging space must fail validation." >&2
      exit 1
    fi
  )
}

test_validate_requires_schema() {
  local fixture_dir="$TEST_ROOT/validate"
  local backup_dir="$fixture_dir/backup"

  mkdir -p "$fixture_dir/lib" "$backup_dir"
  cat >"$fixture_dir/lib/backup-common.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

readonly BACKUP_ROOT="$TEST_BACKUP_ROOT"
readonly MYSQL_CONTAINER="mysql-server"
require_backup_environment() { :; }
require_alarm_environment() { :; }
require_commands() { :; }
mountpoint() { :; }
docker() { :; }
aws() { :; }
# 알림 경로 검증은 별도 테스트에서 다루므로 여기서는 통과시킨다
verify_alarm_endpoint() { :; }
require_dump_staging_space() { printf '%s\n' '1024 9999999999 268437504'; }
mysql_query() {
  if [[ "$1" == *'@@log_bin'* ]]; then
    printf '%s\n' '1 ROW 1 1 1'
  elif [[ "$1" == *'information_schema.schemata'* ]]; then
    printf '%s\n' "$TEST_SCHEMA_EXISTS"
  elif [[ "$1" == *'information_schema.tables'* ]]; then
    printf '%s\n' '1024'
  else
    echo "Unexpected validation query: $1" >&2
    return 1
  fi
}
EOF

  TEST_BACKUP_ROOT="$backup_dir" \
  TEST_SCHEMA_EXISTS=1 \
  MYSQL_BACKUP_BUCKET="test-bucket" \
  MYSQL_DATABASE="test_database" \
  AWS_REGION="ap-northeast-2" \
  ALARM_API_HOST="172.31.0.10" \
  ALARM_API_PORTS="8080 9080" \
  ALARM_API_HEALTH_PORTS="8081 9081" \
  ALARM_API_TOKEN="test-token" \
  MYSQL_BACKUP_LIB_DIR="$fixture_dir/lib" \
    bash "$PROJECT_DIR/scripts/mysql_backup/bin/mysql-backup-validate" >/dev/null

  if TEST_BACKUP_ROOT="$backup_dir" \
    TEST_SCHEMA_EXISTS=0 \
    MYSQL_BACKUP_BUCKET="test-bucket" \
    MYSQL_DATABASE="missing_database" \
    AWS_REGION="ap-northeast-2" \
    ALARM_API_HOST="172.31.0.10" \
    ALARM_API_PORTS="8080 9080" \
    ALARM_API_HEALTH_PORTS="8081 9081" \
    ALARM_API_TOKEN="test-token" \
    MYSQL_BACKUP_LIB_DIR="$fixture_dir/lib" \
      bash "$PROJECT_DIR/scripts/mysql_backup/bin/mysql-backup-validate" >/dev/null 2>&1; then
    echo "Validation must reject a missing backup database." >&2
    exit 1
  fi
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
curl() { return 0; }
instance_id() { printf '%s' 'i-test'; }
alarm_sent=false
alarm_handled=false
send_backup_alarm() {
  if [[ -n "${TEST_ALARM_LOG:-}" ]]; then
    printf '%s\n' "$1" >>"$TEST_ALARM_LOG"
  fi
  alarm_sent=true
  return 0
}
fail_with_alarm() {
  echo "$2" >&2
  send_backup_alarm "$1" "$2"
  alarm_handled=true
  exit 1
}
alarm_on_unexpected_failure() {
  local exit_code=$?
  if ((exit_code != 0)) && [[ "$alarm_handled" != "true" ]]; then
    send_backup_alarm "$1" "unexpected failure with exit code $exit_code"
  fi
  return 0
}
alarm_if_upload_delayed() { :; }
aws() { printf '%s' "${TEST_S3_KEYS:-}"; }
require_dump_staging_space() {
  if [[ -n "${TEST_SPACE_CHECK_LOG:-}" ]]; then
    printf '%s\n' 'checked' >>"$TEST_SPACE_CHECK_LOG"
  fi
  if [[ "${TEST_DUMP_SPACE_AVAILABLE:-true}" != "true" ]]; then
    echo "Insufficient backup staging space." >&2
    return 1
  fi
  printf '%s\n' '1024 9999999999 268437504'
}
date() {
  case "${*: -1}" in
    +%Y%m%dT%H%M%SZ) printf '%s\n' '20260716T030000Z' ;;
    +%Y-%m-%dT%H:%M:%SZ) printf '%s\n' '2026-07-16T03:00:00Z' ;;
    +%Y/%m/%d) printf '%s\n' '2026/07/16' ;;
    +%H%M%S) printf '%s\n' '030000' ;;
    +%s)
      if [[ " $* " == *" -d "* ]]; then
        printf '%s\n' "${TEST_JOB_CREATED_EPOCH:-1784170800}"
      else
        printf '%s\n' "${TEST_NOW_EPOCH:-1784170800}"
      fi
      ;;
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
  uploaded_keys=()
  while IFS= read -r uploaded_key; do
    uploaded_keys+=("$uploaded_key")
  done <"$upload_log"
  for ((i = 0; i < ${#uploaded_keys[@]}; i += 2)); do
    assert_equals \
      "${uploaded_keys[i]}.manifest.json" \
      "${uploaded_keys[i + 1]}" \
      "each binlog must be uploaded immediately before its manifest"
  done
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

  rm -f "$backup_dir/state/binlog-last-uploaded"
  : >"$upload_log"
  TEST_BACKUP_ROOT="$backup_dir" \
  TEST_MYSQL_DATA_DIR="$data_dir" \
  TEST_UPLOAD_LOG="$upload_log" \
  TEST_MANIFEST_CAPTURE="$manifest_capture" \
  TEST_ACTIVE_FILE="$active_file" \
  TEST_FLUSH_LOG="$flush_log" \
  TEST_S3_KEYS=$'binlog/2026/07/16/025000-11111111-2222-3333-4444-555555555555-binlog.000001.manifest.json\tbinlog/2026/07/16/025500-11111111-2222-3333-4444-555555555555-binlog.000003.manifest.json' \
  MYSQL_BACKUP_LIB_DIR="$fixture_dir/lib" \
    bash "$PROJECT_DIR/scripts/mysql_backup/bin/mysql-backup-binlog" >/dev/null
  assert_equals "10" "$(wc -l <"$upload_log" | tr -d ' ')" "S3 recovery must resume before a manifest gap and repair the local closed chain"

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
  local space_check_log="$fixture_dir/space-checks"

  write_fake_common "$fixture_dir"
  mkdir -p "$backup_dir/staging" "$backup_dir/state"
  mkdir -p "$backup_dir/staging/dump-20260715T030000Z"
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
    TEST_SPACE_CHECK_LOG="$space_check_log" \
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
  [[ ! -e "$backup_dir/staging/dump-20260715T030000Z" ]]
  assert_equals \
    "20260716T030000Z" \
    "$(<"$backup_dir/state/dump-current")" \
    "a failed dump attempt must retain a valid retry job id"
  [[ ! -e "$backup_dir/state/dump-current.tmp" ]]
  cp "$manifest_capture" "$first_manifest"
  rm -f "$manifest_capture"
  sleep 1

  TEST_BACKUP_ROOT="$backup_dir" \
  TEST_MYSQL_DATA_DIR="$fixture_dir/mysql" \
  TEST_UPLOAD_LOG="$upload_log" \
  TEST_MANIFEST_CAPTURE="$manifest_capture" \
  MYSQL_DATABASE="test_database" \
  TEST_FAIL_MANIFEST_ONCE=1 \
  TEST_FAIL_MARKER="$fixture_dir/failed-once" \
  TEST_SPACE_CHECK_LOG="$space_check_log" \
  MYSQL_BACKUP_LIB_DIR="$fixture_dir/lib" \
    bash "$PROJECT_DIR/scripts/mysql_backup/bin/mysql-backup-dump" >/dev/null

  cmp "$first_manifest" "$manifest_capture"
  assert_equals \
    "1" \
    "$(wc -l <"$space_check_log" | tr -d ' ')" \
    "an upload-only retry must not reserve space for another dump"
  [[ ! -e "$backup_dir/state/dump-current" ]]
}

test_dump_rejects_insufficient_space() {
  local fixture_dir="$TEST_ROOT/dump-no-space"
  local backup_dir="$fixture_dir/backup"
  local docker_log="$fixture_dir/docker-calls"
  local space_check_log="$fixture_dir/space-checks"

  write_fake_common "$fixture_dir"
  mkdir -p "$backup_dir/staging" "$backup_dir/state"
  cat >>"$fixture_dir/lib/backup-common.sh" <<'EOF'
docker() {
  printf '%s\n' 'called' >>"$TEST_DOCKER_LOG"
  printf '%s\n' "-- CHANGE REPLICATION SOURCE TO SOURCE_LOG_FILE='binlog.000003', SOURCE_LOG_POS=157;"
}
EOF

  if TEST_BACKUP_ROOT="$backup_dir" \
    TEST_MYSQL_DATA_DIR="$fixture_dir/mysql" \
    TEST_DOCKER_LOG="$docker_log" \
    TEST_SPACE_CHECK_LOG="$space_check_log" \
    TEST_DUMP_SPACE_AVAILABLE=false \
    MYSQL_DATABASE="test_database" \
    MYSQL_BACKUP_LIB_DIR="$fixture_dir/lib" \
      bash "$PROJECT_DIR/scripts/mysql_backup/bin/mysql-backup-dump" >/dev/null 2>&1; then
    echo "A dump must not start without sufficient staging space." >&2
    exit 1
  fi

  assert_equals "1" "$(wc -l <"$space_check_log" | tr -d ' ')" "the dump must check free space"
  [[ ! -e "$docker_log" ]]
  assert_equals \
    "20260716T030000Z" \
    "$(<"$backup_dir/state/dump-current")" \
    "a failed space check must retain the retry job"
}

test_dump_discards_stale_job() {
  local fixture_dir="$TEST_ROOT/dump-stale"
  local backup_dir="$fixture_dir/backup"
  local upload_log="$fixture_dir/uploads"
  local manifest_capture="$fixture_dir/manifest.json"
  local docker_log="$fixture_dir/docker-calls"
  local old_job_id="20260715T030000Z"
  local new_job_id="20260716T030000Z"

  write_fake_common "$fixture_dir"
  mkdir -p "$backup_dir/staging/dump-$old_job_id" "$backup_dir/state"
  printf '%s\n' "$old_job_id" >"$backup_dir/state/dump-current"
  printf '%s\n' 'old dump' >"$backup_dir/staging/dump-$old_job_id/test_database-$old_job_id.sql.gz"
  cat >>"$fixture_dir/lib/backup-common.sh" <<'EOF'
docker() {
  printf '%s\n' 'called' >>"$TEST_DOCKER_LOG"
  printf '%s\n' "-- CHANGE REPLICATION SOURCE TO SOURCE_LOG_FILE='binlog.000003', SOURCE_LOG_POS=157;"
  printf '%s\n' 'CREATE TABLE example (id bigint);'
}
EOF

  TEST_BACKUP_ROOT="$backup_dir" \
  TEST_MYSQL_DATA_DIR="$fixture_dir/mysql" \
  TEST_UPLOAD_LOG="$upload_log" \
  TEST_MANIFEST_CAPTURE="$manifest_capture" \
  TEST_DOCKER_LOG="$docker_log" \
  TEST_JOB_CREATED_EPOCH=1784140000 \
  TEST_NOW_EPOCH=1784170800 \
  MYSQL_DATABASE="test_database" \
  MYSQL_BACKUP_LIB_DIR="$fixture_dir/lib" \
    bash "$PROJECT_DIR/scripts/mysql_backup/bin/mysql-backup-dump" >/dev/null

  [[ ! -e "$backup_dir/staging/dump-$old_job_id" ]]
  [[ ! -e "$backup_dir/state/dump-current" ]]
  assert_equals "1" "$(wc -l <"$docker_log" | tr -d ' ')" "a stale job must create a new dump"
  if ! head -1 "$upload_log" | grep -q "dump/2026/07/16/$new_job_id/"; then
    echo "A stale job must upload under a new dump prefix." >&2
    exit 1
  fi
}

test_backup_alarm_port_fallback() {
  (
    export MYSQL_BACKUP_BUCKET="test-bucket"
    export MYSQL_DATABASE="test_database"
    export AWS_REGION="ap-northeast-2"
    export ALARM_API_HOST="172.31.0.10"
    export ALARM_API_PORTS="8080 9080"
    export ALARM_API_TOKEN="test-token"
    # shellcheck source=../lib/backup-common.sh
    source "$PROJECT_DIR/scripts/mysql_backup/lib/backup-common.sh"

    local attempt_log="$TEST_ROOT/alarm-attempts"
    : >"$attempt_log"
    instance_id() { printf '%s' 'i-test'; }
    # 활성 슬롯만 응답하는 상황을 재현한다. blue 는 닫혀 있고 green 만 열려 있다.
    curl() {
      local argument
      for argument in "$@"; do
        case "$argument" in
          http://*:8080/*) echo "8080" >>"$attempt_log"; return 7 ;;
          http://*:9080/*) echo "9080" >>"$attempt_log"; return 0 ;;
        esac
      done
      return 0
    }

    send_backup_alarm DUMP_FAILED "test detail" >/dev/null
    assert_equals \
      "8080 9080" \
      "$(tr '\n' ' ' <"$attempt_log" | sed 's/ $//')" \
      "the alarm must try the blue port first and fall back to the green port"
    assert_equals "true" "$alarm_sent" "a delivered alarm must mark the sent flag"
  )
}

test_backup_alarm_failure_does_not_break_backup() {
  (
    export MYSQL_BACKUP_BUCKET="test-bucket"
    export MYSQL_DATABASE="test_database"
    export AWS_REGION="ap-northeast-2"
    export ALARM_API_HOST="172.31.0.10"
    export ALARM_API_PORTS="8080 9080"
    export ALARM_API_TOKEN="test-token"
    # shellcheck source=../lib/backup-common.sh
    source "$PROJECT_DIR/scripts/mysql_backup/lib/backup-common.sh"

    instance_id() { printf '%s' 'i-test'; }
    curl() { return 7; }

    if ! send_backup_alarm DUMP_FAILED "test detail" >/dev/null 2>&1; then
      echo "An alarm delivery failure must not fail the backup." >&2
      exit 1
    fi
    assert_equals "false" "$alarm_sent" "an undelivered alarm must not mark the sent flag"
  )
}

test_backup_alarm_skipped_without_configuration() {
  (
    export MYSQL_BACKUP_BUCKET="test-bucket"
    export MYSQL_DATABASE="test_database"
    export AWS_REGION="ap-northeast-2"
    # shellcheck source=../lib/backup-common.sh
    source "$PROJECT_DIR/scripts/mysql_backup/lib/backup-common.sh"

    curl() { echo "The alarm must not be sent without configuration." >&2; return 99; }
    instance_id() { printf '%s' 'i-test'; }

    send_backup_alarm DUMP_FAILED "test detail" >/dev/null 2>&1
    assert_equals "false" "$alarm_sent" "an alarm without configuration must not be marked as sent"
  )
}

test_backup_alarm_detail_escaping() {
  (
    export MYSQL_BACKUP_BUCKET="test-bucket"
    export MYSQL_DATABASE="test_database"
    export AWS_REGION="ap-northeast-2"
    # shellcheck source=../lib/backup-common.sh
    source "$PROJECT_DIR/scripts/mysql_backup/lib/backup-common.sh"

    assert_equals \
      'say \"hi\"' \
      "$(json_escape 'say "hi"')" \
      "double quotes in the detail must be escaped for json"
    assert_equals \
      'a\\b' \
      "$(json_escape 'a\b')" \
      "backslashes in the detail must be escaped for json"
    assert_equals \
      'first\nsecond' \
      "$(json_escape "$(printf 'first\nsecond')")" \
      "newlines in the detail must be escaped for json"
  )
}

# 명시적으로 알린 실패를 EXIT 트랩이 기본 유형으로 다시 보내지 않는지 본다.
# 전송에 실패한 경우까지 확인한다. 이때 재전송이 일어나면 유형과 원인이 함께 뒤바뀐다.
test_unexpected_failure_alarm_is_sent_once() {
  local run_case
  run_case() {
    local delivery_succeeds="$1"
    local send_log="$2"
    (
      export MYSQL_BACKUP_BUCKET="test-bucket"
      export MYSQL_DATABASE="test_database"
      export AWS_REGION="ap-northeast-2"
      export ALARM_API_HOST="172.31.0.10"
      export ALARM_API_PORTS="8080 9080"
      export ALARM_API_TOKEN="test-token"
      # shellcheck source=../lib/backup-common.sh
      source "$PROJECT_DIR/scripts/mysql_backup/lib/backup-common.sh"

      instance_id() { printf '%s' 'i-test'; }
      # 실제 스크립트와 같은 순서로 트랩을 걸어 기본 유형이 덮어쓰는지 확인한다.
      trap 'alarm_on_unexpected_failure BINLOG_UPLOAD_FAILED' EXIT
      curl() {
        local argument
        for argument in "$@"; do
          case "$argument" in
            *"$ALARM_PATH")
              printf '%s\n' "$SEND_LOG_TYPE" >>"$SEND_LOG"
              ;;
          esac
        done
        [[ "$DELIVERY_SUCCEEDS" == "true" ]]
      }

      DELIVERY_SUCCEEDS="$delivery_succeeds" SEND_LOG="$send_log" \
        SEND_LOG_TYPE="attempt" \
        fail_with_alarm BINLOG_GAP_DETECTED "binlog chain is broken" 2>/dev/null
    )
  }

  # 전송에 성공하면 한 번만 시도한다.
  local delivered_log="$TEST_ROOT/alarm-send-delivered"
  : >"$delivered_log"
  run_case true "$delivered_log" || true
  assert_equals \
    "1" \
    "$(wc -l <"$delivered_log" | tr -d ' ')" \
    "an already reported failure must not be alarmed twice"

  # 전송에 실패해도 트랩이 기본 유형으로 다시 보내지 않는다.
  # 포트 두 개를 모두 시도하므로 시도 횟수는 2회이고, 3회 이상이면 트랩이 재전송한 것이다.
  local failed_log="$TEST_ROOT/alarm-send-failed"
  : >"$failed_log"
  run_case false "$failed_log" || true
  assert_equals \
    "2" \
    "$(wc -l <"$failed_log" | tr -d ' ')" \
    "an undelivered explicit alarm must not be resent with the default type"
}

test_binlog_delay_alarm_threshold() {
  (
    export MYSQL_BACKUP_BUCKET="test-bucket"
    export MYSQL_DATABASE="test_database"
    export AWS_REGION="ap-northeast-2"
    # shellcheck source=../lib/backup-common.sh
    source "$PROJECT_DIR/scripts/mysql_backup/lib/backup-common.sh"

    local alarm_log="$TEST_ROOT/delay-alarm.log"
    local success_file="$TEST_ROOT/last-binlog-success"
    send_backup_alarm() { printf '%s\n' "$1" >>"$alarm_log"; alarm_sent=true; return 0; }
    date() {
      if [[ "$*" == "-u +%s" ]]; then
        printf '%s\n' '1784170800'
      else
        command date "$@"
      fi
    }

    # 한 주기(5분)만 지난 상태는 정상 범위로 보고 알리지 않는다.
    : >"$alarm_log"
    printf '%s\n' '1784170500' >"$success_file"
    alarm_if_upload_delayed "$success_file" 900
    assert_equals "" "$(cat "$alarm_log")" "a single missed cycle must not raise a delay alarm"

    # 세 주기를 넘기면 지연으로 알린다.
    : >"$alarm_log"
    printf '%s\n' '1784169600' >"$success_file"
    alarm_if_upload_delayed "$success_file" 900
    assert_equals \
      "BINLOG_UPLOAD_DELAYED" \
      "$(cat "$alarm_log")" \
      "an upload delayed beyond three cycles must be alarmed"
    assert_equals \
      "false" \
      "$alarm_handled" \
      "a delay alarm must not suppress the alarm for an actual failure in the same run"

    # 마지막 성공 기록이 없으면 판단하지 않는다.
    : >"$alarm_log"
    rm -f "$success_file"
    alarm_if_upload_delayed "$success_file" 900
    assert_equals "" "$(cat "$alarm_log")" "a missing success record must not raise a delay alarm"
  )
}

# 설치 검증이 tcp 연결이 아니라 health 응답과 401 응답을 확인하는지 본다.
test_verify_alarm_endpoint() {
  local run_case
  run_case() {
    local health_ok="$1"
    local alarm_status="$2"
    (
      export MYSQL_BACKUP_BUCKET="test-bucket"
      export MYSQL_DATABASE="test_database"
      export AWS_REGION="ap-northeast-2"
      # shellcheck source=../lib/backup-common.sh
      source "$PROJECT_DIR/scripts/mysql_backup/lib/backup-common.sh"

      export ALARM_API_HOST="172.31.0.10"
      export ALARM_API_PORTS="8080 9080"
      export ALARM_API_HEALTH_PORTS="8081 9081"

      # health 는 본문을, 알림 경로는 상태 코드를 돌려주도록 흉내낸다.
      curl() {
        local argument
        for argument in "$@"; do
          case "$argument" in
            *"/actuator/health")
              if [[ "$FAKE_HEALTH_OK" == "true" ]]; then
                printf '%s\n' '{"status":"UP"}'
                return 0
              fi
              return 22
              ;;
            *"/internal/alarms/db-backup")
              printf '%s' "$FAKE_ALARM_STATUS"
              return 0
              ;;
          esac
        done
        return 0
      }

      FAKE_HEALTH_OK="$health_ok" FAKE_ALARM_STATUS="$alarm_status" \
        verify_alarm_endpoint >/dev/null 2>&1
    )
  }

  if ! run_case true 401; then
    echo "A healthy api server that rejects an invalid token must pass verification." >&2
    exit 1
  fi
  # 애플리케이션이 기동하지 않았다면 tcp 가 열려 있어도 통과하면 안 된다.
  if run_case false 401; then
    echo "Verification must fail when no management port reports UP." >&2
    exit 1
  fi
  # 경로가 배포되지 않아 404 가 오면 통과하면 안 된다.
  if run_case true 404; then
    echo "Verification must fail when the alarm endpoint is not deployed." >&2
    exit 1
  fi
}

test_alarm_target_validation() {
  (
    export MYSQL_BACKUP_BUCKET="test-bucket"
    export MYSQL_DATABASE="test_database"
    export AWS_REGION="ap-northeast-2"
    # shellcheck source=../lib/backup-common.sh
    source "$PROJECT_DIR/scripts/mysql_backup/lib/backup-common.sh"

    if ! validate_alarm_target "172.31.56.245" "8080 9080" 2>/dev/null; then
      echo "A valid alarm target must pass validation." >&2
      exit 1
    fi

    # 옥텟 범위를 넘는 주소는 형식만 맞아도 거부한다.
    if validate_alarm_target "999.999.999.999" "8080" 2>/dev/null; then
      echo "An out-of-range octet must be rejected." >&2
      exit 1
    fi
    if validate_alarm_target "172.31.56" "8080" 2>/dev/null; then
      echo "An incomplete address must be rejected." >&2
      exit 1
    fi

    # 포트 범위를 벗어나면 거부한다.
    if validate_alarm_target "172.31.56.245" "0" 2>/dev/null; then
      echo "Port 0 must be rejected." >&2
      exit 1
    fi
    if validate_alarm_target "172.31.56.245" "65536" 2>/dev/null; then
      echo "Port 65536 must be rejected." >&2
      exit 1
    fi
    if validate_alarm_target "172.31.56.245" "8080 70000" 2>/dev/null; then
      echo "An out-of-range port in the list must be rejected." >&2
      exit 1
    fi
  )
}

test_upload_idempotency
test_dump_space_calculation
test_validate_requires_schema
test_binlog_chain
test_dump_retry_manifest
test_dump_rejects_insufficient_space
test_dump_discards_stale_job
test_backup_alarm_port_fallback
test_backup_alarm_failure_does_not_break_backup
test_backup_alarm_skipped_without_configuration
test_backup_alarm_detail_escaping
test_unexpected_failure_alarm_is_sent_once
test_binlog_delay_alarm_threshold
test_alarm_target_validation
test_verify_alarm_endpoint
echo "All MySQL backup tests passed."
