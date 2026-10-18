#!/usr/bin/env bash
#
# 검증 계층 스크립트 공용 함수. 컨테이너 안에서만 사용한다.
#
# 결과는 $VERIFY_RESULTS 파일에 "상태<TAB>계층<TAB>항목<TAB>사유" 형식으로 누적되고,
# verify.sh 가 마지막에 print_summary 로 한 번에 출력한다.
#
# 상태
#   PASS     검사를 실행했고 통과
#   FAIL     검사를 실행했고 실패 (전체 exit 1)
#   SKIPPED  검사를 실행하지 못함 (자격증명 없음 등). 통과로 간주하지 않으며 사유를 반드시 남긴다.
#            --strict 에서는 실패로 처리한다.

readonly WORK_DIR=/work
cd "$WORK_DIR" || exit 1

# Terraform 루트/모듈 디렉터리 (validate 대상, 이 파일을 source 하는 계층 스크립트에서 사용)
# shellcheck disable=SC2034
readonly TF_ROOT_DIRS=(bootstrap environment/global environment/prod environment/stage environment/monitoring environment/load_test)
# shellcheck disable=SC2034
readonly TF_MODULE_DIRS=(modules/app_stack modules/monitoring_stack modules/shared_resources)

record() {
  local status="$1" layer="$2" name="$3" reason="${4:-}"
  printf '%s\t%s\t%s\t%s\n' "$status" "$layer" "$name" "$reason" >>"$VERIFY_RESULTS"
  case "$status" in
    PASS) printf '  \033[32mPASS\033[0m     %s\n' "$name" ;;
    FAIL) printf '  \033[31mFAIL\033[0m     %s\n' "$name" ;;
    SKIPPED) printf '  \033[33mSKIPPED\033[0m  %s — %s\n' "$name" "$reason" ;;
  esac
}

section() {
  printf '\n\033[1m== %s ==\033[0m\n' "$1"
}

# 명령을 실행해 PASS/FAIL 을 기록한다. 실패 시에만 전체 출력을 보여준다.
# usage: run_check <layer> <name> <command...>
run_check() {
  local layer="$1" name="$2"
  shift 2

  local log
  log="$(mktemp)"
  if (cd "$WORK_DIR" && "$@") >"$log" 2>&1; then
    record PASS "$layer" "$name"
  else
    record FAIL "$layer" "$name"
    sed 's/^/    | /' "$log"
  fi
  rm -f "$log"
}

print_summary() {
  local pass fail skipped
  pass="$(grep -c '^PASS' "$VERIFY_RESULTS" || true)"
  fail="$(grep -c '^FAIL' "$VERIFY_RESULTS" || true)"
  skipped="$(grep -c '^SKIPPED' "$VERIFY_RESULTS" || true)"

  section "요약"
  printf '  PASS %s / FAIL %s / SKIPPED %s\n' "$pass" "$fail" "$skipped"

  if [[ "$fail" -gt 0 ]]; then
    echo
    echo "  실패 항목:"
    awk -F'\t' '$1=="FAIL" {printf "    - [%s] %s\n", $2, $3}' "$VERIFY_RESULTS"
  fi
  if [[ "$skipped" -gt 0 ]]; then
    echo
    echo "  미검증 항목 (통과가 아님):"
    awk -F'\t' '$1=="SKIPPED" {printf "    - [%s] %s — %s\n", $2, $3, $4}' "$VERIFY_RESULTS"
  fi

  if [[ "$fail" -gt 0 ]]; then
    return 1
  fi
  if [[ "$skipped" -gt 0 && "${VERIFY_STRICT:-false}" == true ]]; then
    echo
    echo "  --strict: 미검증 항목이 있어 실패로 처리합니다."
    return 1
  fi
  return 0
}

# 셸 스크립트 목록: *.sh 와 shebang 이 있는 확장자 없는 파일 (.tftpl 은 L3 에서 렌더링 후 검사)
list_shell_scripts() {
  local f
  find "$WORK_DIR" \( -name .terraform -o -name .git -o -name node_modules \) -prune -o -type f -print \
    | LC_ALL=C sort \
    | while read -r f; do
        case "$f" in
          *.sh) echo "$f" ;;
          */*.*) ;;
          *) head -n1 "$f" 2>/dev/null | grep -qE '^#!.*(ba)?sh' && echo "$f" ;;
        esac
      done
  return 0
}
