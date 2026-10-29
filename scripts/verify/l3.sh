#!/usr/bin/env bash
#
# L3 동작 테스트: 서버에서 실제로 실행되는 스크립트/템플릿이 의도대로 동작하는지 검사한다.
#
set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

readonly LAYER=L3
readonly RENDER_DIR=scripts/verify/render
readonly RENDERED_OUT=/tmp/verify-rendered

section "L3 동작 테스트"

# 0. 템플릿 inventory: 레포의 모든 .tftpl 이 렌더링 fixture 에 등록돼 있어야 한다.
#    등록을 빠뜨리면 아래 렌더링/shellcheck 가 그 템플릿을 검사하지 않고 PASS 하기 때문이다.
template_inventory() {
  python3 - "$RENDER_DIR/templates.tf" <<'PY'
import pathlib, re, sys
fixture = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
registered = set(re.findall(r'\$\{local\.repo\}/([^"]+\.tftpl)"', fixture))
actual = {
    str(p) for p in pathlib.Path(".").rglob("*.tftpl")
    if ".terraform" not in p.parts
}
missing = sorted(actual - registered)
stale = sorted(registered - actual)
for path in missing:
    print(f"fixture 미등록: {path} → scripts/verify/render/templates.tf 에 호출부와 같은 변수로 추가하세요")
for path in stale:
    print(f"존재하지 않는 템플릿 참조: {path}")
sys.exit(1 if missing or stale else 0)
PY
}
run_check "$LAYER" "template inventory" template_inventory

# 1. .tftpl 렌더링 (fixture: scripts/verify/render/templates.tf)
#    base64 로 감싸 terraform console 의 문자열 이스케이프($${ 등)를 피한다.
render_templates() {
  terraform -chdir="$RENDER_DIR" init -backend=false -input=false >/dev/null
  rm -rf "$RENDERED_OUT" && mkdir -p "$RENDERED_OUT"
  echo 'base64encode(jsonencode(local.rendered))' \
    | terraform -chdir="$RENDER_DIR" console \
    | python3 -c '
import base64, json, pathlib, sys
encoded = json.loads(sys.stdin.read())
for name, content in json.loads(base64.b64decode(encoded)).items():
    (pathlib.Path(sys.argv[1]) / name).write_text(content)
    print(name)
' "$RENDERED_OUT"
}
run_check "$LAYER" "template render" render_templates

# 2. 렌더링된 user_data / SSM 스크립트 lint
#    템플릿 수정은 plan 변경을 만들기 때문에 기존 경고는 baseline 파일(파일명 + SC 코드)로만 예외 처리한다.
shellcheck_rendered() {
  local baseline=scripts/verify/baseline/rendered-shellcheck.txt
  local findings
  findings="$(mktemp)"
  shellcheck --severity=warning --format=gcc "$RENDERED_OUT"/*.sh >"$findings" || true
  python3 - "$baseline" "$findings" <<'PY'
import re, sys
allowed = set()
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.split("#", 1)[0].split()
    if len(line) == 2:
        allowed.add(tuple(line))
failed = False
for finding in open(sys.argv[2], encoding="utf-8").read().splitlines():
    m = re.match(r"^.*/([^/:]+):\d+:\d+: \w+: .*\[(SC\d+)\]$", finding)
    if m and (m.group(1), m.group(2)) in allowed:
        continue
    print(finding)
    failed = True
sys.exit(1 if failed else 0)
PY
}
if compgen -G "$RENDERED_OUT/*.sh" >/dev/null; then
  run_check "$LAYER" "shellcheck (rendered templates)" shellcheck_rendered
else
  record SKIPPED "$LAYER" "shellcheck (rendered templates)" "렌더링 실패로 검사 대상 없음"
fi

# 3. 스크립트 단위 테스트
run_check "$LAYER" "mysql_backup tests" bash scripts/mysql_backup/tests/run.sh
# scripts/*/tests/test_*.py 전체 (load_test, verify 등)
# tests 디렉터리에 __init__.py 가 없어 discover 대신 모듈 경로로 실행한다. (load-test-run.yml 과 동일한 방식)
python_tests() {
  local -a modules
  mapfile -t modules < <(find scripts -path '*/tests/test_*.py' | sed 's|/|.|g; s|\.py$||' | sort)
  python3 -m unittest -q "${modules[@]}"
}
run_check "$LAYER" "python tests" python_tests
