# solid-connection-infra

solid-connection 서비스의 AWS 인프라를 Terraform으로 관리하는 IaC 레포지토리입니다.

## 디렉토리 구조

```text
solid-connection-infra/
├── .claude/skills/verify/    # 변경 검증 스킬 (L1~L3 절차)
├── config/
│   ├── secrets/              # git submodule (solid-connection-infra-secret)
│   └── side-infra/           # Alloy 모니터링 설정 (config.alloy.tftpl)
├── modules/
│   ├── app_stack/            # Prod/Stage 공통 모듈 (EC2, RDS, Security Groups)
│   ├── monitoring_stack/     # 모니터링 전용 모듈 (EC2, Security Groups)
│   ├── shared_resources/     # Global 공유 자원 (S3, CloudFront, Lambda, ACM)
│   └── common/               # 공용 스크립트 (docker_setup.sh)
├── scripts/
│   ├── verify/               # 변경 검증 파이프라인 (L1~L3, Docker 기반)
│   ├── mysql_backup/         # DB EC2 MySQL 백업 스크립트
│   └── load_test/            # 부하 테스트 스크립트
└── environment/
    ├── global/               # 공유 자원 환경 (shared_resources 모듈 사용)
    ├── prod/                 # 프로덕션 환경
    ├── stage/                # 스테이징 환경
    ├── load_test/            # 부하 테스트 환경
    └── monitoring/           # 모니터링 환경
```

- `modules/` : 재사용 가능한 Terraform 모듈. 직접 apply하지 않음
- `environment/` : 실제 배포 단위. 각 환경마다 독립적인 state 파일 보유
- `config/secrets/` : git submodule로 관리되는 민감 변수 (.tfvars). 직접 수정 금지

## Terraform 백엔드

S3 Remote Backend를 사용하며, Terraform 1.10+의 S3 네이티브 락 기능을 사용합니다 (DynamoDB 불필요).

- **S3 버킷**: `solid-connection-tfstate`
- **버전 관리, 암호화, 퍼블릭 접근 차단** 활성화
- **DynamoDB 락 미사용**: Terraform 1.10+ S3 네이티브 락으로 대체

환경별 state 파일 경로:

| 환경       | key                                |
| ---------- | ---------------------------------- |
| global     | `env/global/terraform.tfstate`     |
| prod       | `env/prod/terraform.tfstate`       |
| stage      | `env/stage/terraform.tfstate`      |
| load_test  | `env/load_test/terraform.tfstate`  |
| monitoring | `env/monitoring/terraform.tfstate` |

## 협업 워크플로우

```text
feature/* 브랜치 Push
    → PR 생성
    → terraform plan 자동 실행 (GitHub Actions)
    → 팀 코드 리뷰 및 plan 결과 확인
    → 승인 후 main 머지
    → terraform apply 자동 실행 (GitHub Actions)
```

- `main` 브랜치에 머지되면 해당 환경의 apply가 자동으로 실행됩니다
- `feature/*`, `refactor/*`, `fix/*` 브랜치는 PR을 통해서만 병합합니다

## 로컬 개발 환경 설정

### IAM 자격증명 (Read-only)

로컬에서는 **plan만 가능**합니다. apply 권한은 GitHub Actions OIDC 전용입니다.

개발자는 읽기 전용 IAM Policy가 부여된 자격증명을 발급받아 사용합니다:

- AWS read-only 권한 (`Describe*`, `List*`, `Get*`)
- S3 `GetObject` on `solid-connection-tfstate` (state 읽기)
- S3 `PutObject` / `DeleteObject` on `*.tflock` 허용 (plan 시 네이티브 락 획득/해제)
- S3 `PutObject` / `DeleteObject` on `*.tfstate` 미부여 (state 쓰기 차단 → apply 불가)

`~/.aws/credentials` 또는 환경 변수로 설정:

```bash
export AWS_PROFILE=solid-connection-readonly
```

### tfvars 파일

secrets submodule이 초기화되어 있어야 합니다:

```bash
git submodule update --init --recursive
```

각 환경의 tfvars는 `config/secrets/<env>.tfvars`에 위치합니다.

### plan 실행

```bash
cd environment/<환경명>
terraform init
terraform plan -var-file="../../config/secrets/<환경명>.tfvars"
```

검증 파이프라인으로 실행할 때는 `scripts/verify/verify.sh l2`를 씁니다. CI와 같은 tfvars 조합과 prod SSM 터널을 자동으로 처리합니다.

## 변경 검증 절차 (L1 ~ L4)

인프라 변경은 아래 계층으로 검증합니다. 상세 내용은 `scripts/verify/README.md`를 참고합니다.

| 계층           | 수행              | 방법                                                      |
| -------------- | ----------------- | --------------------------------------------------------- |
| L1 정적 검사   | 로컬 + CI         | `scripts/verify/verify.sh`                                |
| L2 plan 검사   | 로컬 + CI         | `scripts/verify/verify.sh l2 --expect .verify/expect.txt` |
| L3 동작 테스트 | 로컬 + CI         | `scripts/verify/verify.sh`                                |
| L4 런타임 검증 | 작업자 (apply 후) | 아래 "L4 런타임 검증" 참고                                |

- Code Agent는 코드를 수정한 뒤 커밋/PR 전에 **`verify` 스킬**(`.claude/skills/verify`)을 따라 L1~L3를 통과시킵니다.
- 실행하지 못한 검사(`SKIPPED`)는 통과가 아닙니다. PR에 사유와 함께 명시합니다.
- 검증 정책 파일(`scripts/verify/docker/tflint.hcl`, `.trivyignore.yaml`, `scripts/verify/baseline/*`, `scripts/verify/policies/*`)은 인프라 변경 PR에서 함께 수정하지 않습니다.

### L4 런타임 검증

L4는 apply 후 실제 리소스가 의도대로 동작하는지 확인하는 단계입니다. `main`에 머지되면 prod까지 바로 apply되므로, **L4는 prod에 반영된 뒤에 수행된다**는 점을 전제로 합니다.

1. **PR 작성 시 (Agent)**: 변경 내용을 가장 잘 아는 시점에, 이 변경을 apply한 뒤 확인할 항목을 PR 본문의 "런타임 확인 체크리스트 (L4)"에 작성합니다.
   - 각 항목에는 **대상 / 확인 명령 / 기대 결과**를 적습니다.
   - 확인하는 방법이 없는 변경이라면 그 사실을 적습니다.
2. **apply 후 (작업자)**: GitHub Actions apply가 끝나면 체크리스트를 수행하고, 결과를 PR 댓글로 남깁니다.
3. **실패 시**: 즉시 원인을 확인하고, revert PR 또는 수정 PR을 올립니다.

변경 유형별 체크리스트 예시:

| 변경 유형                           | 확인 예시                                                                                      |
| ----------------------------------- | ---------------------------------------------------------------------------------------------- |
| nginx 설정 (`nginx_*.sh.tftpl`)     | `sudo nginx -t`, `systemctl is-active nginx`, 외부/내부 경로별 `curl -I` 응답 코드             |
| side-infra (redis, alloy)           | `docker ps`로 컨테이너 상태 확인, Grafana/Loki에 로그 유입 확인                                |
| MySQL 백업 (`scripts/mysql_backup`) | `systemctl list-timers 'mysql-backup-*'`, `journalctl -u mysql-backup-dump`, S3 최신 객체 시각 |
| DB EC2 (`mysql_setup.sh.tftpl`)     | `docker ps`로 mysql 상태 확인, 마운트(`findmnt /mnt/mysql-data`), 애플리케이션 DB 연결         |
| Security Group                      | 허용해야 할 경로는 연결되고, 차단해야 할 경로는 연결되지 않는지 확인                           |
| S3 / CloudFront / Lambda            | 실제 업로드 → CloudFront URL 응답, 썸네일/리사이즈 결과                                        |

> 서버 내부 확인은 SSM 세션(`aws ssm start-session`)으로 합니다. 개발자 read-only 자격증명에 SSM 세션 권한이 있는지는 팀 정책에 따라 다르므로, 권한이 없다면 권한이 있는 팀원에게 L4를 요청합니다.

## 주의사항

- **`terraform apply`는 로컬에서 실행하지 않습니다.** apply는 GitHub Actions에서만 실행됩니다
- **`terraform.tfstate` 파일을 직접 수정하지 않습니다**
- **`config/secrets/` 하위 파일을 직접 수정하지 않습니다** (submodule 별도 관리)
- 모든 인프라 변경은 PR을 통해 plan 결과를 팀이 검토한 후 진행합니다

## AWS 리소스 구성

- **리전**: `ap-northeast-2` (서울)
- **공통 태그**: `Project = "solid-connection"`, `Env = "<환경명>"`
- **주요 서비스**: EC2, RDS (MySQL), S3, CloudFront, Lambda, ACM, Security Groups
