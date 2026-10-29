# L2 plan 정책 규칙

`scripts/verify/plan_check.py policy` 가 이 디렉터리의 `*.py` 파일(`_` 로 시작하는 파일 제외)을 규칙으로 불러와 plan 의 각 리소스 변경에 적용합니다.

> 구체적인 규칙은 별도 논의로 확정합니다. 현재 등록된 규칙은 없습니다.
> 규칙 파일은 검증 정책이므로 **인프라 변경 PR 에서 함께 수정하지 않고**, 별도 PR 로 리뷰합니다.

## 규칙 파일 형식

```python
# scripts/verify/policies/no_stateful_destroy.py (예시)
RULE_ID = "STATEFUL-001"
SEVERITY = "block"  # block: 실패 처리 / warn: 출력만
DESCRIPTION = "상태를 가진 리소스의 삭제/교체 금지"

STATEFUL_TYPES = {"aws_db_instance", "aws_ebs_volume", "aws_s3_bucket"}


def check(action, change):
    """위반이면 사유 문자열, 아니면 None 을 반환한다.

    action: "create" | "update" | "delete" | "replace"
    change: terraform show -json 의 resource_changes[] 항목
            (type, address, change.before, change.after 등 사용 가능)
    """
    if change["type"] in STATEFUL_TYPES and action in ("delete", "replace"):
        return f"{action} 은 허용되지 않습니다"
    return None
```

출력에는 규칙이 반환한 메시지만 표시되므로, 메시지에 민감한 값(`change.after` 의 비밀번호 등)을 넣지 않습니다.
