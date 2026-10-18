---
name: verify
description: solid-connection-infra 의 인프라 변경(Terraform, user_data 템플릿, 스크립트, 워크플로우)을 L1 정적 검사 / L2 plan 검사 / L3 동작 테스트로 검증하고, 실패하면 고쳐서 다시 검증한다. 코드를 수정한 뒤 커밋/PR 전에, 또는 사용자가 검증을 요청할 때 사용한다.
---

# 인프라 변경 검증 (L1 ~ L3)

이 레포의 변경은 사람이 한 줄씩 읽는 대신 **기계가 판단할 수 있는 것은 전부 이 스킬로 검증**하고,
사람은 압축된 근거(검증 결과 + plan 변경 목록 + L4 체크리스트)만 보고 의도를 판단한다.

실제 검증 로직은 `scripts/verify/` 에 있고 CI 도 같은 스크립트를 쓴다. 이 스킬은 실행 순서와 대응 방법만 정한다.
상세 설명: `scripts/verify/README.md`

> 이 파일의 원본은 `.claude/skills/verify/SKILL.md` 이고, `.agents/skills/verify/SKILL.md` 는 다른 Code Agent 용 동일 사본이다.
> 수정할 때는 원본을 고친 뒤 사본에 그대로 복사한다. (L1 `skill copies in sync` 검사가 두 파일이 같은지 확인한다)

## 절차

### 1. 작업 전: 의도 선언

코드를 고치기 전에 plan 에 나와야 할 리소스 변경을 `.verify/expect.txt` 에 적는다. (gitignore 대상)
같은 내용을 PR 본문의 `verify-expect` 코드 블록에도 그대로 옮긴다. **CI 는 PR 본문의 블록으로 의도를 대조하고, 블록이 없으면 plan job 이 실패한다.**

```text
# <env> <create|update|delete|replace> <address, glob 허용>
prod update module.prod_stack.aws_instance.api_server
```

- 교체(replace)가 예상되면 반드시 `replace` 로 적는다. `update` 로 적으면 실제 교체를 놓친다.
- 리소스 변경이 없어야 하는 작업(스크립트 수정, 리팩터링 등)이라면 빈 파일(빈 블록)을 둔다. 그러면 "변경 없음"이 검증된다.
- 환경 줄이 없는 환경은 "변경 없음"을 의도한 것으로 본다.
- load_test 는 평소 내려가 있어 plan 이 전체 create 로 나온다. load_test 를 건드리는 작업이면 `load_test create *` 처럼 선언한다.

### 2. 구현 후: L1 + L3 (항상)

```bash
scripts/verify/verify.sh
```

`FAIL` 이 있으면 출력된 로그를 보고 고친 뒤 다시 실행한다. 모두 `PASS` 가 될 때까지 반복한다.

- `terraform fmt` 실패: 호스트의 terraform 버전이 다를 수 있으므로, 검증 이미지로 포맷한다.
  `docker run --rm -v "$PWD:/workspace" -w /workspace "$(scripts/verify/verify.sh --print-image)" terraform fmt -recursive bootstrap environment modules scripts`
- 새 `.tftpl` 을 추가했거나 템플릿 변수를 바꿨다면 `scripts/verify/render/templates.tf` 도 갱신한다. (빠뜨리면 L3 `template inventory` 가 실패한다)

### 3. Terraform 변경이 있으면: L2

```bash
scripts/verify/verify.sh l2 --expect .verify/expect.txt
```

- 대상 환경은 origin/main 대비 변경 파일로 자동 감지된다. (`--env` 로 직접 지정할 수도 있다.)
- `intent` 가 `FAIL` 이면:
  - **의도에 없는 변경**: 코드가 의도와 다르게 동작하는 것이다. 코드를 고친다. 의도 파일을 실제 plan 에 맞춰 고치지 않는다.
  - **의도했으나 plan 에 없음**: 구현이 빠졌거나, 의도 자체가 잘못된 것이다. 의도가 틀렸다면 사용자에게 설명하고 고친다.
- plan 전문이 필요하면 `.verify/l2/<env>.plan.txt` 를 읽는다.
- `delete` 또는 `replace` 가 있으면, 의도한 것이더라도 사용자에게 명시적으로 알린다.

### 4. 결과 보고

PR 본문(또는 사용자에게 보내는 보고)에 아래 내용을 남긴다.

- 의도 블록 (```` ```verify-expect ```` — PR 템플릿에 자리가 있다)
- 실행한 계층과 요약 (`PASS n / FAIL n / SKIPPED n`)
- **SKIPPED 항목과 사유.** 검증하지 못한 것을 검증한 것처럼 쓰지 않는다.
- L2 리소스 변경 목록 (delete/replace 는 강조)
- L4 런타임 확인 체크리스트 (CLAUDE.md 의 "L4 런타임 검증" 참고)

## 하지 말 것

- **검사를 통과시키려고 검증 정책을 수정하지 않는다.** 아래 파일은 사람이 별도 PR 로 관리한다.
  `scripts/verify/docker/tflint.hcl`, `.trivyignore.yaml`, `scripts/verify/baseline/*`, `scripts/verify/policies/*`
  정책 때문에 막혔고 그 정책이 틀렸다고 판단되면, 수정하지 말고 사용자에게 사유와 함께 보고한다.
- `SKIPPED` 를 `PASS` 로 보고하지 않는다.
- user_data 템플릿(`*.tftpl`)을 lint 경고만 보고 고치지 않는다. 템플릿이 바뀌면 plan 에 인스턴스 변경이 생긴다. 고칠 필요가 있다면 L2 로 영향을 확인하고 사용자에게 알린다.
- `terraform apply` 는 실행하지 않는다. (apply 는 GitHub Actions 전용)
