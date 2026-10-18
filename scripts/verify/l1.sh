#!/usr/bin/env bash
#
# L1 정적 검사: 코드를 실행하지 않고 판단할 수 있는, 빠르고 결과가 확정적인 검사.
#
set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

readonly LAYER=L1

section "L1 정적 검사"

# 1. 포맷 (작업 복사본에는 secrets 가 없지만, 대상 디렉터리를 명시해 tfvars 가 diff 로 출력될 여지를 없앤다)
run_check "$LAYER" "terraform fmt" \
  terraform fmt -check -recursive -diff bootstrap environment modules scripts

# 2. 문법/참조 검증 (backend 없이 init 하므로 자격증명이 필요 없다)
validate_dir() {
  terraform -chdir="$1" init -backend=false -input=false >/dev/null
  terraform -chdir="$1" validate -no-color
}
for dir in "${TF_ROOT_DIRS[@]}" "${TF_MODULE_DIRS[@]}"; do
  run_check "$LAYER" "terraform validate ($dir)" validate_dir "$dir"
done

# 3. Terraform lint (AWS ruleset 포함, environment/* 에서 호출하는 로컬 모듈까지 검사)
run_check "$LAYER" "tflint" \
  tflint --recursive --config /opt/tflint/tflint.hcl --format compact

# 4. IaC 보안 스캔 (HIGH 이상만 실패 처리, 예외는 .trivyignore.yaml 에 사유와 함께 기록)
run_check "$LAYER" "trivy config" \
  trivy config --quiet --exit-code 1 --severity HIGH,CRITICAL \
    --ignorefile .trivyignore.yaml \
    --skip-dirs config/secrets --skip-dirs '**/.terraform' \
    .

# 5. 셸 스크립트 lint (warning 이상만 실패 처리)
mapfile -t shell_scripts < <(list_shell_scripts)
run_check "$LAYER" "shellcheck (${#shell_scripts[@]} files)" \
  shellcheck --severity=warning --external-sources --source-path=SCRIPTDIR "${shell_scripts[@]}"

# 6. GitHub Actions 워크플로우 lint (run 블록은 shellcheck 로 함께 검사됨)
# .git 없이 복사한 작업 디렉터리라 워크플로우 파일을 직접 넘긴다.
# run 블록의 shellcheck 도 위 셸 스크립트 lint 와 같은 기준(warning 이상)을 적용한다.
run_check "$LAYER" "actionlint" \
  env SHELLCHECK_OPTS=--severity=warning bash -c 'actionlint .github/workflows/*.yml'

# 7. 에이전트별 스킬 사본 동기화 (원본: .claude/skills, 사본: .agents/skills)
#    Windows 에서 symlink 가 깨지지 않도록 복사본을 두고, 내용이 갈라지지 않았는지만 검사한다.
skill_copies_in_sync() {
  local src dst rc=0
  for src in .claude/skills/*/; do
    dst=".agents/skills/$(basename "$src")"
    if ! diff -r "$src" "$dst"; then
      echo "→ 원본($src)을 사본($dst)에 그대로 복사하세요: cp -R ${src}. $dst/"
      rc=1
    fi
  done
  return "$rc"
}
run_check "$LAYER" "skill copies in sync" skill_copies_in_sync
