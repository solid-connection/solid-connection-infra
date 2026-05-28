# 부하 테스트 자동화

이 디렉터리는 부하 테스트용 GitHub Actions workflow에서 사용하는 스크립트를 담고 있습니다.

전체 흐름은 다음과 같습니다.

1. **Load Test Start**: 임시 부하 테스트 인프라를 만들고 stage를 준비합니다.
2. **Load Test Run**: 별도 k6 부하 생성 EC2에서 k6를 실행합니다.
3. **Load Test Stop**: stage를 복구하고 임시 부하 테스트 스택을 제거합니다.

## 규칙

- 환경 Terraform에 대해 로컬에서 `terraform apply` 또는 `terraform destroy`를 실행하지 않습니다.
- 시작, 실행, 종료는 GitHub Actions에서 수행합니다.
- k6는 stage EC2에서 실행하지 않습니다. 부하 테스트용 Terraform이 생성한 별도 load-generator EC2에서 실행합니다.
- SSH private key를 사용하지 않습니다. EC2 명령은 SSM RunCommand로 실행합니다.

## 필요한 설정

`environment/load_test`는 `config/secrets/load_test.tfvars`를 사용합니다.

스냅샷 복원 방식에서는 load-test DB root 계정을 별도로 만들지 않습니다. load-test datasource username/password는 prod datasource Parameter Store 값을 복사해 사용합니다.

주요 확인값:

- `prod_rds_identifier`: snapshot을 조회할 prod RDS identifier
- `kms_key_arn`: 복원된 load-test RDS storage encryption에 사용할 KMS key ARN
- `prod_db_username_parameter_name`: 기본값 `/solid-connection/prod/spring.datasource.username`
- `prod_db_password_parameter_name`: 기본값 `/solid-connection/prod/spring.datasource.password`

그 외 부하 테스트 설정값은 Terraform 기본값, GitHub Actions variable, workflow 입력값으로 처리합니다.

## Load Test Start

GitHub에서 **Actions > Load Test Start**를 수동 실행합니다.

입력값:

- `switch_stage_to_loadtest`: `true` 또는 `false`
  - `true`이면 데이터 준비 후 stage 앱을 `dev,loadtest` profile로 재기동합니다.

Start workflow 동작:

1. GitHub Actions가 `environment/load_test`에서 Terraform apply를 실행합니다.
2. Terraform이 최신 prod RDS 자동 snapshot을 조회합니다.
3. Terraform이 해당 snapshot에서 load-test RDS를 복원합니다.
4. Terraform이 보안 그룹과 `c7i.large` 타입의 k6 load-generator EC2를 생성합니다.
5. Terraform이 load-test datasource 값을 Parameter Store에 기록합니다.
   - datasource URL은 복원된 load-test RDS endpoint를 사용합니다.
   - datasource username/password는 prod datasource Parameter Store 값을 사용합니다.
6. `scripts/load_test/start.sh`가 Terraform output에서 필요한 값을 읽습니다.
7. `switch_stage_to_loadtest=true`이면 stage 앱을 `dev,loadtest` profile로 재기동합니다.

## Load Test Run

GitHub에서 **Actions > Load Test Run**을 수동 실행합니다.

입력값:

- `vus`: k6 virtual user 수입니다. 예: `10`
- `iterations`: VU당 반복 횟수입니다. 예: `10`
- `max_duration`: 최대 실행 시간입니다. 예: `30s`, `5m`, `15m`, `1h`
- `target_base_url`
  - 선택값입니다. 비워두면 Terraform output `load_test_target_base_url`을 사용합니다.
- `prometheus_remote_write_url`
  - 선택값입니다. 비워두면 Terraform output `k6_prometheus_remote_write_url`을 사용합니다.

Run workflow 동작:

1. `scripts/load_test/run_k6.sh`가 Terraform output에서 load-generator EC2 ID와 k6 기본값을 읽습니다.
2. load-generator EC2의 SSM agent가 online 상태가 될 때까지 기다립니다.
3. SSM RunCommand로 k6 파일을 load-generator EC2에 동기화합니다.
4. k6 binary가 없으면 `set_up_xk6.sh`로 Prometheus remote-write 지원이 포함된 k6를 빌드합니다.
5. load-generator EC2에서 `whole-user-flow.js`를 실행합니다.

동기화되는 k6 파일:

- `createPost.json`
- `updatePost.json`
- `whole-user-flow.js`
- `set_up_xk6.sh`

## 결과 확인

간단한 실행 결과는 **Load Test Run** GitHub Actions 로그에서 확인합니다.

k6 스크립트는 Prometheus remote-write로도 지표를 전송합니다.

- 기본 remote-write URL은 Terraform output `k6_prometheus_remote_write_url`을 사용합니다.
- workflow 입력값 `prometheus_remote_write_url`로 override할 수 있습니다.
- k6 지표에는 요청 수, 실패율, 응답 시간, p90, p95, p99, 평균, 최소, 최대값이 포함됩니다.
- API 호출에는 `name`, `testid`, `time` tag가 붙어 endpoint와 실행 시점별로 필터링할 수 있습니다.

## Load Test Stop

GitHub에서 **Actions > Load Test Stop**을 수동 실행합니다.

입력값:

- `restore_stage_dev`: `true` 또는 `false`
  - `true`이면 stage 앱을 기존 dev compose 구성으로 되돌립니다.
- `destroy_rds`: `true` 또는 `false`
  - `true`이면 load-test Terraform stack을 destroy합니다.

Stop workflow 동작:

1. `scripts/load_test/stop.sh`가 `environment/load_test`에서 Terraform init을 실행합니다.
2. `restore_stage_dev=true`이면 stage를 dev datasource 구성으로 복구합니다.
3. `destroy_rds=true`이면 Terraform destroy로 load-test RDS와 load-generator EC2를 제거합니다.

## 참고

- GitHub Actions는 OIDC로 AWS role을 assume합니다.
- private submodule checkout에는 `GH_PAT`를 사용합니다.
- prod/stage EC2는 `Name` tag로 조회합니다.
- prod/load-test DB 계정 정보는 Parameter Store에서 읽습니다.
- load-test RDS 보안 그룹은 prod/stage API EC2 보안 그룹에서 들어오는 MySQL 접근만 허용합니다.
