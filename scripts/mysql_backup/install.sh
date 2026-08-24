#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SOURCE_DIR
readonly CONFIG_SOURCE="${1:-$SOURCE_DIR/mysql-backup.env}"
readonly INSTALL_LIB_DIR="/usr/local/lib/solid-connection/mysql-backup"
readonly INSTALL_BIN_DIR="/usr/local/libexec/solid-connection"
readonly CONFIG_DIR="/etc/solid-connection"
readonly CONFIG_FILE="$CONFIG_DIR/mysql-backup.env"
readonly INSTALL_LOCK_FILE="/run/lock/solid-connection-mysql-backup-install.lock"
# 대기 상한입니다. 진행 중인 백업 작업과 다른 설치 트랜잭션을 기다릴 때 함께 사용합니다.
# binlog는 최대 4분, dump는 최대 2시간 실행되므로, dump가 도는 중이라면
# 기다리기보다 중단하고 다른 시각에 다시 실행하는 편이 낫습니다.
readonly LOCK_WAIT_SECONDS=300
readonly BINLOG_TIMER_UNIT="mysql-backup-binlog.timer"
readonly DUMP_TIMER_UNIT="mysql-backup-dump.timer"
readonly DUMP_SERVICE_UNIT="mysql-backup-dump.service"
# dump 스크립트가 manifest 업로드까지 성공한 뒤에만 기록하는 파일입니다.
# 존재하면 S3 에 복구 가능한 dump 가 최소 하나 있다는 뜻입니다.
readonly DUMP_SUCCESS_STATE_FILE="/mnt/mysql-data/mysql-backup/state/last-dump-success"
readonly -a TIMER_UNITS=(
  "$BINLOG_TIMER_UNIT"
  "$DUMP_TIMER_UNIT"
)

if ((EUID != 0)); then
  echo "The installer must run as root." >&2
  exit 1
fi
if [[ ! -f "$CONFIG_SOURCE" ]]; then
  echo "Backup environment file is missing." >&2
  exit 1
fi

for command_name in aws bash cp curl docker flock gzip install mountpoint mv sha256sum systemctl systemd-analyze; do
  command -v "$command_name" >/dev/null || {
    echo "Required command is not installed: $command_name" >&2
    exit 1
  }
done

if ! mountpoint -q /mnt/mysql-data; then
  echo "/mnt/mysql-data is not mounted; refusing to create backup files on the root volume." >&2
  exit 1
fi

# GitHub Actions와 수동 실행이 겹쳐도 하나의 설치 트랜잭션만 진행합니다.
exec 200>"$INSTALL_LOCK_FILE"
if ! flock -w "$LOCK_WAIT_SECONDS" 200; then
  echo "Another installation is already in progress; aborting." >&2
  exit 1
fi

install -d -m 755 -o root -g root "$INSTALL_LIB_DIR" "$INSTALL_BIN_DIR" "$CONFIG_DIR"
install -d -m 700 -o root -g root \
  /mnt/mysql-data/mysql-backup \
  /mnt/mysql-data/mysql-backup/staging \
  /mnt/mysql-data/mysql-backup/state

TRANSACTION_DIR="$(mktemp -d /tmp/mysql-backup-install-transaction.XXXXXX)"
readonly TRANSACTION_DIR
readonly CANDIDATE_DIR="$TRANSACTION_DIR/candidate"
readonly ROLLBACK_DIR="$TRANSACTION_DIR/rollback"
install -d -m 700 "$CANDIDATE_DIR/lib" "$CANDIDATE_DIR/bin" "$CANDIDATE_DIR/systemd" "$ROLLBACK_DIR"
trap 'rm -rf -- "$TRANSACTION_DIR"' EXIT

install -m 644 "$SOURCE_DIR/lib/backup-common.sh" "$CANDIDATE_DIR/lib/backup-common.sh"
for script in "$SOURCE_DIR"/bin/*; do
  install -m 755 "$script" "$CANDIDATE_DIR/bin/$(basename "$script")"
done
install -m 600 "$CONFIG_SOURCE" "$CANDIDATE_DIR/mysql-backup.env"
install -m 644 "$SOURCE_DIR"/systemd/*.service "$SOURCE_DIR"/systemd/*.timer "$CANDIDATE_DIR/systemd/"

load_candidate_config() {
  local key
  local value

  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    case "$key" in
      MYSQL_BACKUP_BUCKET|MYSQL_DATABASE|AWS_REGION|ALARM_API_HOST|ALARM_API_PORTS|ALARM_API_HEALTH_PORTS|ALARM_API_TOKEN)
        printf -v "$key" '%s' "$value"
        export "$key"
        ;;
      *)
        echo "Unsupported backup configuration key: $key" >&2
        return 1
        ;;
    esac
  done <"$CANDIDATE_DIR/mysql-backup.env"
}

# 현재 설치를 건드리기 전에 후보 스크립트와 설정을 검증합니다.
for script in "$CANDIDATE_DIR"/bin/* "$CANDIDATE_DIR/lib/backup-common.sh"; do
  bash -n "$script"
done
load_candidate_config
MYSQL_BACKUP_LIB_DIR="$CANDIDATE_DIR/lib" \
  "$CANDIDATE_DIR/bin/mysql-backup-validate"

declare -a TARGETS=()
declare -A TIMER_WAS_ENABLED=()
declare -A TIMER_WAS_ACTIVE=()
transaction_started=false
transaction_committed=false

register_target() {
  local target="$1"
  local backup="$ROLLBACK_DIR${target}"

  TARGETS+=("$target")
  if [[ -e "$target" || -L "$target" ]]; then
    install -d -m 700 "$(dirname "$backup")"
    cp -a "$target" "$backup"
  fi
}

atomic_install() {
  local source="$1"
  local target="$2"
  local mode="$3"
  local temporary="${target}.new"

  rm -f -- "$temporary"
  install -m "$mode" -o root -g root "$source" "$temporary"
  mv -Tf "$temporary" "$target"
}

# 타이머를 켜기 전에 백업 작업 락을 놓습니다.
# Persistent=true 로 즉시 트리거되는 작업도 같은 락을 얻어야 하므로,
# 설치가 락을 쥔 채 타이머를 켜면 그 작업이 그대로 건너뛰어집니다.
# 아직 열지 않은 상태에서도 호출될 수 있어 실패를 무시합니다.
# fd 는 닫지 않습니다. exec 에 붙인 리다이렉션은 셸 전체에 영구 적용되어
# 이후 오류 메시지가 사라지고, 락은 flock -u 만으로 해제됩니다.
release_backup_locks() {
  flock -u 198 2>/dev/null || true
  flock -u 199 2>/dev/null || true
}

rollback_installation() {
  local target
  local backup
  local timer

  for target in "${TARGETS[@]}"; do
    backup="$ROLLBACK_DIR${target}"
    if [[ -e "$backup" || -L "$backup" ]]; then
      rm -f -- "$target"
      cp -a "$backup" "$target"
    else
      rm -f -- "$target"
    fi
  done

  systemctl daemon-reload || true
  for timer in "${TIMER_UNITS[@]}"; do
    if [[ "${TIMER_WAS_ENABLED[$timer]}" == "true" ]]; then
      systemctl enable "$timer" >/dev/null 2>&1 || true
    else
      systemctl disable "$timer" >/dev/null 2>&1 || true
    fi
    if [[ "${TIMER_WAS_ACTIVE[$timer]}" == "true" ]]; then
      systemctl start "$timer" >/dev/null 2>&1 || true
    else
      systemctl stop "$timer" >/dev/null 2>&1 || true
    fi
  done
}

cleanup() {
  local exit_code=$?

  trap - EXIT
  if [[ "$transaction_started" == "true" && "$transaction_committed" != "true" ]]; then
    echo "Installation failed; restoring the previous backup pipeline." >&2
    set +e
    release_backup_locks
    rollback_installation
  fi
  rm -rf -- "$TRANSACTION_DIR"
  exit "$exit_code"
}
trap cleanup EXIT

for timer in "${TIMER_UNITS[@]}"; do
  if systemctl is-enabled --quiet "$timer" 2>/dev/null; then
    TIMER_WAS_ENABLED["$timer"]="true"
  else
    TIMER_WAS_ENABLED["$timer"]="false"
  fi
  if systemctl is-active --quiet "$timer" 2>/dev/null; then
    TIMER_WAS_ACTIVE["$timer"]="true"
  else
    TIMER_WAS_ACTIVE["$timer"]="false"
  fi
  register_target "/etc/systemd/system/timers.target.wants/$timer"
done

register_target "$INSTALL_LIB_DIR/backup-common.sh"
for script in "$CANDIDATE_DIR"/bin/*; do
  register_target "$INSTALL_BIN_DIR/$(basename "$script")"
done
register_target "$CONFIG_FILE"
for unit in "$CANDIDATE_DIR"/systemd/*; do
  register_target "/etc/systemd/system/$(basename "$unit")"
done
transaction_started=true

# 교체 구간에 타이머가 발화하면 스크립트가 락을 얻지 못해 그 주기의 백업을 건너뜁니다.
# binlog는 다음 주기가 따라잡지만 dump는 하루 한 번이라 그날 복구 기준점이 사라집니다.
# 락을 잡기 전에 타이머를 멈춰 새 발화를 막고, 멈춘 사이에 놓친 발화는 Persistent=true 로
# 타이머를 다시 켜는 시점에 즉시 실행되게 합니다. 실패하면 cleanup 이 이전 상태로 되돌립니다.
# 최초 설치에는 유닛 파일이 아직 없어 stop 이 실패하므로, 앞에서 확인한 활성 상태를 기준으로 멈춥니다.
for timer in "${TIMER_UNITS[@]}"; do
  if [[ "${TIMER_WAS_ACTIVE[$timer]}" == "true" ]]; then
    systemctl stop "$timer"
  fi
done

# 이미 실행 중인 dump/binlog가 끝난 뒤 교체하여 한 작업에서 서로 다른 버전이 섞이지 않게 합니다.
# 무기한 대기하면 SSM 세션이 유휴로 끊겨 원인을 알 수 없는 실패가 되므로 상한을 둡니다.
exec 198>/mnt/mysql-data/mysql-backup/state/dump.lock
exec 199>/mnt/mysql-data/mysql-backup/state/binlog.lock
echo "Waiting for any running backup job to finish (up to ${LOCK_WAIT_SECONDS}s)..."
if ! flock -w "$LOCK_WAIT_SECONDS" 198; then
  echo "A mysqldump backup is still running after ${LOCK_WAIT_SECONDS}s; aborting the installation." >&2
  echo "Retry outside the dump window (03:00 KST, up to 2h)." >&2
  exit 1
fi
if ! flock -w "$LOCK_WAIT_SECONDS" 199; then
  echo "A binlog backup is still running after ${LOCK_WAIT_SECONDS}s; aborting the installation." >&2
  echo "A binlog job normally finishes within 4 minutes, so check whether it is stuck." >&2
  exit 1
fi

atomic_install "$CANDIDATE_DIR/lib/backup-common.sh" "$INSTALL_LIB_DIR/backup-common.sh" 644
for script in "$CANDIDATE_DIR"/bin/*; do
  atomic_install "$script" "$INSTALL_BIN_DIR/$(basename "$script")" 755
done
atomic_install "$CANDIDATE_DIR/mysql-backup.env" "$CONFIG_FILE" 600
declare -a INSTALLED_UNIT_TARGETS=()
for unit in "$CANDIDATE_DIR"/systemd/*; do
  unit_target="/etc/systemd/system/$(basename "$unit")"
  atomic_install "$unit" "$unit_target" 644
  INSTALLED_UNIT_TARGETS+=("$unit_target")
done

systemd-analyze verify "${INSTALLED_UNIT_TARGETS[@]}"
systemctl daemon-reload

# 교체가 끝났고 타이머도 아직 꺼져 있어 이 시점부터는 락이 필요하지 않습니다.
release_backup_locks

systemctl enable --now "${TIMER_UNITS[@]}"
transaction_committed=true

# Persistent 는 마지막 트리거 기록이 있어야 놓친 발화를 따라잡습니다.
# 기록이 없는 최초 설치에서는 다음 03:00 까지 dump 가 생기지 않는데,
# 기준점이 되는 dump 가 없으면 binlog 만으로는 재생 시작점이 없어 복구할 수 없습니다.
# 그래서 성공한 dump 가 없으면 스케줄을 기다리지 않고 바로 만듭니다.
#
# 판단 기준으로 타이머 stamp 파일을 쓰면 양쪽으로 어긋납니다.
# 발화 사실만 기록해 dump 성공을 보장하지 않고, 서비스를 수동으로 시작하면
# 갱신되지 않아 다음 발화 전까지 재설치마다 dump 가 쌓입니다.
# Object Lock 이 걸린 버킷에서는 그렇게 쌓인 객체를 14일 동안 지울 수 없습니다.
if [[ ! -s "$DUMP_SUCCESS_STATE_FILE" ]]; then
  echo "No successful dump is recorded; creating the first dump now so that binlogs have a recovery base."
  # dump 는 최대 2시간까지 실행될 수 있어 완료를 기다리지 않습니다.
  # --no-block 은 시작 요청까지만 확인하므로 실행 결과는 알림과 journalctl 로 확인합니다.
  # 실패하면 성공 기록이 남지 않아 다음 설치가 다시 시도합니다.
  # 설치는 이미 커밋되었으므로, 요청이 실패해도 설치를 실패로 만들지 않고 사실만 알립니다.
  if ! systemctl start --no-block "$DUMP_SERVICE_UNIT"; then
    echo "Failed to request the first dump. There is no recovery base until it succeeds," >&2
    echo "so run 'systemctl start $DUMP_SERVICE_UNIT' manually or wait for 03:00 KST." >&2
  fi
else
  echo "A successful dump is already recorded; leaving the backup schedule untouched."
fi

systemctl --no-pager --full status "${TIMER_UNITS[@]}"
