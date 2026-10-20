#!/usr/bin/env python3
"""L2 plan 검사: `terraform show -json` 결과를 데이터로 다룬다.

subcommands
  summary   리소스 단위 변경 목록 (주소 + action). 값은 출력하지 않는다.
  policy    scripts/verify/policies/*.py 규칙 실행 (SEVERITY="block" 위반 시 exit 1)
  expect    작업 의도 파일과 실제 변경 대조 (불일치 시 exit 1)
  extract-expect  PR 본문의 ```verify-expect 블록을 의도 파일로 추출 (CI 용, 블록이 없으면 exit 1)
  check-envs      의도에 선언한 환경이 모두 plan 대상인지 확인 (형식 오류 exit 1, 대상 아님 exit 3)

로컬(scripts/verify/l2.sh)과 CI(.github/workflows/terraform-plan.yml)가 같은 스크립트를 사용한다.
"""

import argparse
import fnmatch
import importlib.util
import json
import os
import re
import sys
from pathlib import Path

POLICY_DIR = Path(__file__).resolve().parent / "policies"

# PR 본문에서 의도 블록을 찾는다. (GitHub 웹 편집기는 CRLF 를 쓴다)
EXPECT_BLOCK = re.compile(r"^```verify-expect[ \t]*\r?\n(.*?)^```", re.M | re.S)

# 출력 순서: 위험한 변경이 먼저 보이게 한다.
# forget: Terraform 1.7+ removed 블록(destroy = false)으로 리소스를 state 에서만 제거한다. 실제 리소스는 남는다.
ACTION_ORDER = ["delete", "replace", "forget", "create", "update"]
ACTION_MARK = {"delete": "🔴", "replace": "🟠", "forget": "🟣", "create": "🟢", "update": "🟡"}

# 의도 파일에 쓸 수 있는 환경 (verify.sh / terraform-plan.yml 의 환경과 동일)
ENVS = ["bootstrap", "global", "prod", "stage", "monitoring", "load_test"]


class UnsupportedPlan(Exception):
    """처리 방법을 모르는 plan 내용. 조용히 무시하지 않고 실패로 보고한다."""

# for_each 키는 tfvars 값에서 올 수 있다. (예: mysql_user.users["<DB 사용자명>"])
# 레포가 public 이므로 PR 댓글(--markdown)에서는 키를 가리고 숫자 인덱스(count)만 남긴다.
INSTANCE_KEY = re.compile(r'\["(?:[^"\\]|\\.)*"\]')


def redact_keys(address):
    return INSTANCE_KEY.sub('["…"]', address)


def action_of(change):
    """resource_changes[].change.actions 를 단일 action 으로 정규화한다."""
    actions = change["change"]["actions"]
    if actions in (["delete", "create"], ["create", "delete"]):
        return "replace"
    if actions in (["no-op"], ["read"]):
        return None
    if len(actions) == 1 and actions[0] in ACTION_ORDER:
        return actions[0]
    raise UnsupportedPlan(f"지원하지 않는 plan action {actions}: {redact_keys(change['address'])} (scripts/verify/plan_check.py 갱신 필요)")


def load_changes(plan_path):
    with open(plan_path, encoding="utf-8") as f:
        plan = json.load(f)
    changes = []
    for rc in plan.get("resource_changes", []):
        action = action_of(rc)
        if action:
            changes.append((action, rc["address"], rc))
    changes.sort(key=lambda c: (ACTION_ORDER.index(c[0]), c[1]))
    return changes


def cmd_summary(args):
    changes = load_changes(args.plan)
    counts = {a: sum(1 for c in changes if c[0] == a) for a in ACTION_ORDER}
    # forget 은 드물기 때문에 있을 때만 표시한다.
    header = ", ".join(f"{a} {counts[a]}" for a in ACTION_ORDER if a != "forget" or counts[a])

    if args.markdown:
        if not changes:
            print("변경 없음")
            return 0
        print(f"**리소스 변경**: {header}\n")
        print("| | action | address |")
        print("|---|---|---|")
        for action, address, _ in changes:
            print(f"| {ACTION_MARK[action]} | `{action}` | `{redact_keys(address)}` |")
        if counts["delete"] or counts["replace"]:
            print("\n> ⚠️ delete/replace 가 포함되어 있습니다. 의도한 변경인지 반드시 확인하세요.")
        if counts["forget"]:
            print("\n> ⚠️ forget 은 리소스를 state 에서만 제거합니다. (실제 리소스는 남고 더 이상 Terraform 이 관리하지 않음)")
        return 0

    if not changes:
        print("    변경 없음")
        return 0
    print(f"    {header}")
    for action, address, _ in changes:
        print(f"    {ACTION_MARK[action]} {action:<8} {address}")
    return 0


def load_policies():
    policies = []
    for path in sorted(POLICY_DIR.glob("*.py")):
        if path.name.startswith("_"):
            continue
        spec = importlib.util.spec_from_file_location(f"policy_{path.stem}", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        policies.append(module)
    return policies


def cmd_policy(args):
    changes = load_changes(args.plan)
    try:
        policies = load_policies()
    except Exception as e:  # noqa: BLE001 - 규칙 파일 오류도 CI 댓글에 실패로 보여야 한다
        print(f"    정책 규칙 로드 실패: {type(e).__name__}: {e}")
        return 1
    if not policies:
        # stdout 은 CI 댓글에 실리므로 안내 문구는 stderr 로 보낸다.
        print("    등록된 정책 규칙 없음 (scripts/verify/policies/README.md 참고)", file=sys.stderr)
        return 0

    blocked = False
    for policy in policies:
        for action, address, rc in changes:
            try:
                message = policy.check(action, rc)
            except Exception as e:  # noqa: BLE001 - 규칙 오류를 통과로 오인하지 않도록 실패로 기록한다
                print(f"    [error] {getattr(policy, 'RULE_ID', policy.__name__)} {redact_keys(address)}: 규칙 실행 오류 {type(e).__name__}")
                blocked = True
                continue
            if not message:
                continue
            severity = getattr(policy, "SEVERITY", "block")
            blocked |= severity == "block"
            # policy 출력은 CI 댓글에 실리므로 주소의 for_each 키를 가린다.
            print(f"    [{severity}] {policy.RULE_ID} {redact_keys(address)}: {message}")
    return 1 if blocked else 0


def parse_expect_all(path):
    """의도 파일 형식: `<env> <action> <address glob>`, # 이후는 주석. 모든 줄을 (env, action, pattern) 으로 반환한다."""
    entries = []
    for lineno, raw in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 3 or parts[1] not in ACTION_ORDER:
            raise SystemExit(f"{path}:{lineno}: 형식 오류 (기대: <env> <{'|'.join(ACTION_ORDER)}> <address>): {raw}")
        if parts[0] not in ENVS:
            raise SystemExit(f"{path}:{lineno}: 알 수 없는 환경 '{parts[0]}' (가능: {', '.join(ENVS)}): {raw}")
        entries.append(tuple(parts))
    return entries


def parse_expect(path, env):
    return [(action, pattern) for e, action, pattern in parse_expect_all(path) if e == env]


def cmd_check_envs(args):
    """환경별 plan job 은 자기 환경 줄만 대조하므로, plan 대상이 아닌 환경에 선언한 의도는 아무도 검사하지 않는다.
    그런 선언을 조용히 버리지 않도록 별도로 확인한다."""
    declared = sorted({e for e, _, _ in parse_expect_all(args.expect)})
    unplanned = [e for e in declared if e not in args.planned]
    for env in unplanned:
        print(f"    의도에 선언했지만 plan 대상이 아닌 환경: {env} (이 변경으로 해당 환경 코드가 바뀌지 않았거나 대상에서 빠짐)")
    return 3 if unplanned else 0


def cmd_expect(args):
    changes = load_changes(args.plan)
    expected = parse_expect(args.expect, args.env)

    def matched(action, address, rule):
        # 주소의 [0], ["key"] 를 그대로 쓸 수 있도록 대괄호는 글자 그대로 취급하고 * 와 ? 만 와일드카드로 쓴다.
        pattern = rule[1].replace("[", "\0").replace("]", "[]]").replace("\0", "[[]")
        return action == rule[0] and fnmatch.fnmatchcase(address, pattern)

    unexpected = [(a, addr) for a, addr, _ in changes if not any(matched(a, addr, r) for r in expected)]
    missing = [r for r in expected if not any(matched(a, addr, r) for a, addr, _ in changes)]

    for action, address in unexpected:
        # CI 댓글(--redact)에서는 tfvars 에서 온 for_each 키를 가린다. 의도 패턴은 PR 본문에 이미 공개된 값이다.
        print(f"    의도에 없는 변경: {action} {redact_keys(address) if args.redact else address}")
    for action, pattern in missing:
        print(f"    의도했으나 plan 에 없음: {action} {pattern}")
    return 1 if unexpected or missing else 0


def cmd_extract_expect(args):
    """PR 본문은 신뢰할 수 없는 입력이므로 셸을 거치지 않고 환경 변수로만 받는다."""
    body = os.environ.get(args.body_env, "")
    match = EXPECT_BLOCK.search(body)
    if not match:
        # CI 댓글의 코드 블록 안에 실리므로 백틱을 쓰지 않는다.
        print("    PR 본문에 verify-expect 코드 블록이 없습니다. (리소스 변경이 없어야 하는 작업이면 빈 블록을 둡니다)")
        return 1
    Path(args.out).write_text(match.group(1).replace("\r\n", "\n"), encoding="utf-8")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("summary")
    p.add_argument("plan")
    p.add_argument("--markdown", action="store_true", help="PR 댓글용 markdown 출력")
    p.set_defaults(func=cmd_summary)

    p = sub.add_parser("policy")
    p.add_argument("plan")
    p.set_defaults(func=cmd_policy)

    p = sub.add_parser("expect")
    p.add_argument("plan")
    p.add_argument("--env", required=True)
    p.add_argument("--expect", required=True)
    p.add_argument("--redact", action="store_true", help="CI 댓글용: 주소의 for_each 키를 가림")
    p.set_defaults(func=cmd_expect)

    p = sub.add_parser("check-envs")
    p.add_argument("--expect", required=True)
    p.add_argument("--planned", nargs="*", default=[], help="plan 대상 환경 목록")
    p.set_defaults(func=cmd_check_envs)

    p = sub.add_parser("extract-expect")
    p.add_argument("--body-env", default="PR_BODY", help="PR 본문이 담긴 환경 변수 이름")
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_extract_expect)

    args = parser.parse_args()
    try:
        sys.exit(args.func(args))
    except UnsupportedPlan as e:
        # stdout 으로 내보내 CI 댓글과 로컬 출력 모두에 실패 사유가 보이게 한다.
        print(f"    {e}")
        sys.exit(2)


if __name__ == "__main__":
    main()
