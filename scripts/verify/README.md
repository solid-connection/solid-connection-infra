# scripts/verify

AI(Code Agent)와 사람이 같은 기준으로 인프라 변경을 검증하기 위한 파이프라인입니다. (#89)

| 계층           | 성격                                                                    | 실행 위치                       |
| -------------- | ----------------------------------------------------------------------- | ------------------------------- |
| L1 정적 검사   | 코드만 보고 판단 (fmt, validate, tflint, trivy, shellcheck, actionlint) | 로컬 + CI(`verify.yml`)         |
| L2 plan 검사   | plan 을 JSON 으로 다뤄 변경 목록 / 정책 / 의도 대조                     | 로컬 + CI(`terraform-plan.yml`) |
| L3 동작 테스트 | `.tftpl` 렌더링 후 shellcheck, 스크립트 단위 테스트                     | 로컬 + CI(`verify.yml`)         |
| L4 런타임 검증 | apply 후 실제 리소스 상태 확인                                          | 작업자 (CLAUDE.md, PR 템플릿)   |

## 사용법

필요한 것은 **Docker** 와 **bash** 뿐입니다. (Windows 는 Git Bash 또는 WSL)

```bash
scripts/verify/verify.sh                 # L1 + L3 (기본, 자격증명 불필요)
scripts/verify/verify.sh l2              # 변경된 환경만 plan (origin/main 대비 자동 감지)
scripts/verify/verify.sh l2 --env prod   # 환경 직접 지정
scripts/verify/verify.sh all --expect .verify/expect.txt
```

- 검증 이미지는 처음 실행할 때, 그리고 `docker/` 디렉터리가 바뀌었을 때 자동으로 빌드됩니다. 이미지 태그는 `docker/` 내용의 해시입니다.
- 레포는 컨테이너에 **읽기 전용**으로 마운트되므로, 검증 과정에서 작업 트리가 바뀌지 않습니다.
- provider 와 trivy 캐시는 Docker 볼륨 `solid-connection-verify-cache` 에 저장됩니다.

## 결과 해석

| 상태      | 의미                                                                              |
| --------- | --------------------------------------------------------------------------------- |
| `PASS`    | 검사를 실행했고 통과                                                              |
| `FAIL`    | 검사를 실행했고 실패. 출력된 로그를 보고 수정                                     |
| `SKIPPED` | **실행하지 못함 (통과가 아님)**. 사유를 확인하고, 검증하지 못한 사실을 PR 에 명시 |

`--strict` 를 주면 `SKIPPED` 도 실패로 처리합니다. (CI 에서 사용)

## L2 준비 조건

| 조건                                                             | 없을 때                                                      |
| ---------------------------------------------------------------- | ------------------------------------------------------------ |
| AWS read-only 자격증명 (`AWS_PROFILE=solid-connection-readonly`) | `SKIPPED` (state 버킷에 접근할 수 없으면 다른 계정으로 판단) |
| `git submodule update --init --recursive` (tfvars)               | `SKIPPED`                                                    |
| prod: DB EC2 로의 SSM 포트 포워딩 권한                           | `SKIPPED`                                                    |

plan 전문은 `.verify/l2/<env>.plan.txt` 에 저장됩니다. (gitignore 대상)

### 의도 파일 (`--expect`)

작업 전에 "이 변경으로 plan 에 나와야 하는 리소스 변경"을 적어 두면, 실제 plan 과 기계적으로 대조합니다.
로컬은 `--expect` 파일로, CI(`terraform-plan.yml`)는 **PR 본문의 `verify-expect` 코드 블록**으로 대조합니다. PR 본문에 블록이 없으면 plan job 이 실패합니다.
적지 않은 환경은 "변경 없음"을 의도한 것으로 봅니다. load_test 는 평소 내려가 있어 전체 create 로 나오므로 `load_test create *` 처럼 선언합니다.
의도에 없는 변경과, 의도했지만 plan 에 없는 변경이 모두 `FAIL` 입니다.

```text
# <env> <create|update|delete|replace> <address, glob 허용>
prod  update   module.prod_stack.aws_instance.api_server
prod  create   module.prod_stack.aws_security_group_rule.*
stage update   module.stage_stack.aws_instance.api_server
```

주소의 `*` 와 `?` 만 와일드카드이고, 대괄호는 글자 그대로입니다. (`mysql_user.users[*]`, `aws_instance.web[0]`)

`replace` 는 `update` 와 구분됩니다. 교체가 의도라면 반드시 `replace` 로 적어야 합니다.

## 검증 정책 파일 (사람이 소유)

아래 파일은 "무엇을 통과로 볼지"를 정하는 정책입니다. **인프라 변경 PR 에서 함께 수정하지 않고**, 별도 PR 로 리뷰합니다.
검사를 통과시키기 위해 정책을 완화하지 않습니다.

| 파일                               | 내용                                             |
| ---------------------------------- | ------------------------------------------------ |
| `docker/tflint.hcl`                | tflint 규칙 (기존 코드 baseline 포함)            |
| `../../.trivyignore.yaml`          | trivy 예외 (ID + 경로 + 사유)                    |
| `baseline/rendered-shellcheck.txt` | 렌더링된 템플릿의 기존 shellcheck 경고 예외      |
| `policies/*.py`                    | L2 plan 정책 규칙 ([README](policies/README.md)) |

## 새 템플릿/테스트 추가 시

- 새 `.tftpl` 을 추가했다면 `render/templates.tf` 의 `rendered` 에 호출부와 같은 변수로 항목을 추가합니다.
- `scripts/<name>/tests/test_*.py` 는 L3 가 자동으로 실행합니다.
- 도구 버전은 `docker/Dockerfile` 의 `ARG` 에서 올립니다. (CI 의 `TF_VERSION` 과 terraform 버전을 맞출 것)
