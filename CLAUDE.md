# solid-connection-infra

solid-connection 서비스의 AWS 인프라를 Terraform으로 관리하는 IaC 레포지토리입니다.

## 디렉토리 구조

```
solid-connection-infra/
├── config/
│   ├── secrets/              # git submodule (solid-connection-infra-secret)
│   └── side-infra/           # Alloy 모니터링 설정 (config.alloy.tftpl)
├── modules/
│   ├── app_stack/            # Prod/Stage 공통 모듈 (EC2, RDS, Security Groups)
│   ├── monitoring_stack/     # 모니터링 전용 모듈 (EC2, Security Groups)
│   ├── shared_resources/     # Global 공유 자원 (S3, CloudFront, Lambda, ACM)
│   └── common/               # 공용 스크립트 (docker_setup.sh)
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

| 환경 | key |
|------|-----|
| global | `env/global/terraform.tfstate` |
| prod | `env/prod/terraform.tfstate` |
| stage | `env/stage/terraform.tfstate` |
| load_test | `env/load_test/terraform.tfstate` |
| monitoring | `env/monitoring/terraform.tfstate` |

## 협업 워크플로우

```
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
- S3 `PutObject` / `DeleteObject` 미부여 (state 쓰기 차단 → apply 불가)

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

## 주의사항

- **`terraform apply`는 로컬에서 실행하지 않습니다.** apply는 GitHub Actions에서만 실행됩니다
- **`terraform.tfstate` 파일을 직접 수정하지 않습니다**
- **`config/secrets/` 하위 파일을 직접 수정하지 않습니다** (submodule 별도 관리)
- 모든 인프라 변경은 PR을 통해 plan 결과를 팀이 검토한 후 진행합니다

## AWS 리소스 구성

- **리전**: `ap-northeast-2` (서울)
- **공통 태그**: `Project = "solid-connection"`, `Env = "<환경명>"`
- **주요 서비스**: EC2, RDS (MySQL), S3, CloudFront, Lambda, ACM, Security Groups
