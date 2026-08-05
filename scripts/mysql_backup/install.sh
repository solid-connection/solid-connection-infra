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
readonly -a TIMER_UNITS=(
  mysql-backup-binlog.timer
  mysql-backup-dump.timer
)

if ((EUID != 0)); then
  echo "The installer must run as root." >&2
  exit 1
fi
if [[ ! -f "$CONFIG_SOURCE" ]]; then
  echo "Backup environment file is missing." >&2
  exit 1
fi

for command_name in aws bash cp docker flock gzip install mountpoint mv sha256sum systemctl systemd-analyze; do
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
flock 200

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
      MYSQL_BACKUP_BUCKET|MYSQL_DATABASE|AWS_REGION)
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

# 실행 중인 dump/binlog가 끝난 뒤 교체하여 한 작업에서 서로 다른 버전이 섞이지 않게 합니다.
exec 198>/mnt/mysql-data/mysql-backup/state/dump.lock
exec 199>/mnt/mysql-data/mysql-backup/state/binlog.lock
flock 198
flock 199

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
systemctl enable --now "${TIMER_UNITS[@]}"
transaction_committed=true

systemctl --no-pager --full status "${TIMER_UNITS[@]}"
