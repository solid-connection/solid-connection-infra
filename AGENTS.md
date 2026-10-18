# AGENTS.md

이 레포의 작업 규칙과 구조는 [CLAUDE.md](CLAUDE.md)를 따릅니다. Claude Code 이외의 Code Agent도 같은 규칙을 적용합니다.

## 변경 검증

코드를 수정한 뒤 커밋/PR 전에 아래 검증을 통과시킵니다. 절차와 금지 사항은 `verify` 스킬([.agents/skills/verify/SKILL.md](.agents/skills/verify/SKILL.md), 원본은 `.claude/skills/verify/SKILL.md`)에 있습니다.

```bash
scripts/verify/verify.sh                                  # L1 정적 검사 + L3 동작 테스트
scripts/verify/verify.sh l2 --expect .verify/expect.txt   # L2 plan 검사 (Terraform 변경 시)
```

- 의도(plan 에 나와야 할 리소스 변경)는 PR 본문의 `verify-expect` 블록에 적습니다. CI 가 실제 plan 과 대조합니다.
- `SKIPPED`는 통과가 아닙니다. PR에 사유를 명시합니다.
- L4 런타임 검증 지침은 [CLAUDE.md](CLAUDE.md)의 "L4 런타임 검증"을 따릅니다.
- 검증 정책 파일(`scripts/verify/docker/tflint.hcl`, `.trivyignore.yaml`, `scripts/verify/baseline/*`, `scripts/verify/policies/*`)은 수정하지 않습니다.
- `terraform apply`는 실행하지 않습니다.
