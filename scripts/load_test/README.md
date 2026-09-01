# 부하 테스트 자동화

이 디렉터리는 부하 테스트용 GitHub Actions workflow에서 사용하는 스크립트를 담고 있습니다.

전체 흐름은 다음과 같습니다.

1. **Load Test Start**: 임시 부하 테스트 인프라를 만들고 stage를 준비합니다.
2. **Load Test Run**: k6 부하 생성 EC2를 만들고 k6를 실행한 뒤 기본적으로 제거합니다.
3. **Load Test Stop**: stage를 복구하고 임시 부하 테스트 스택을 제거합니다.

## 규칙

- 환경 Terraform에 대해 로컬에서 `terraform apply` 또는 `terraform destroy`를 실행하지 않습니다.
- 시작, 실행, 종료는 GitHub Actions에서 수행합니다.
- k6는 stage EC2에서 실행하지 않습니다. Run workflow가 생성한 별도 load-generator EC2에서 실행합니다.
- load-generator EC2는 비용 절감을 위해 기본적으로 Run workflow 종료 시 제거합니다.
- SSH private key를 사용하지 않습니다. EC2 명령은 SSM RunCommand로 실행합니다.

## 필요한 설정

`environment/load_test`는 `config/secrets/load_test.tfvars`를 사용합니다.

load-test DB는 RDS snapshot을 복원하지 않고 별도 MySQL EC2로 생성합니다. EC2 user data가 prod MySQL 백업 S3 bucket에서 최신 dump manifest를 찾고, dump 파일을 검증한 뒤 MySQL container에 복원합니다.

Terraform은 datasource URL만 load-test DB EC2 private IP로 갱신합니다. username/password는 읽거나 복사하지 않습니다. load-test datasource username/password는 앱의 Parameter Store 연동이 loadtest 경로에서 직접 읽습니다.

주요 확인값:

- `prod_db_instance_name`: prod MySQL EC2의 Name tag입니다. `load_test_db_ami_id`가 비어 있으면 이 EC2의 AMI를 사용합니다.
- `load_test_db_instance_profile_name`: load-test MySQL EC2에 연결할 사전 생성 IAM instance profile 이름입니다. 기본값은 `solid-connection-load-test-db`이며, Terraform은 IAM 리소스를 생성하지 않습니다.
- `mysql_backup_bucket_name`: prod MySQL dump manifest와 dump 파일이 저장되는 S3 bucket 이름입니다. 기본값은 `solid-connection-prod-mysql-backup`입니다.
- `/solid-connection/loadtest/spring.datasource.username`: 앱이 loadtest profile에서 읽는 DB username입니다.
- `/solid-connection/loadtest/spring.datasource.password`: 앱이 loadtest profile에서 읽는 SecureString입니다.

그 외 부하 테스트 설정값은 Terraform 기본값, GitHub Actions variable, workflow 입력값으로 처리합니다.

## Load Test Start

GitHub에서 **Actions > Load Test Start**를 수동 실행합니다.

입력값:

- `switch_stage_to_loadtest`: `true` 또는 `false`
  - `true`이면 데이터 준비 후 stage 앱을 `dev,loadtest` profile로 재기동합니다.

Start workflow 동작:

1. GitHub Actions가 `environment/load_test`에서 Terraform apply를 실행합니다.
2. Terraform이 prod MySQL EC2와 prod/stage API EC2를 Name tag로 조회합니다.
3. Terraform이 load-test MySQL EC2, 데이터 EBS 볼륨, 보안 그룹을 생성합니다.
4. Terraform이 load-test datasource URL을 Parameter Store에 기록합니다.
   - datasource URL은 load-test MySQL EC2 private IP를 사용합니다.
   - datasource username/password는 Parameter Store에 복사하지 않습니다.
5. load-test MySQL EC2 user data가 prod MySQL 백업 S3 bucket의 최신 dump를 내려받아 복원합니다.
6. `scripts/load_test/start.sh`가 Terraform output에서 필요한 값을 읽습니다.
7. `scripts/load_test/start.sh`가 SSM으로 load-test MySQL EC2의 `cloud-init` 완료와 `/opt/solid-connection/load-test-db-ready` marker 생성을 확인합니다. 기본 대기 시간은 3600초입니다.
8. `switch_stage_to_loadtest=true`이면 stage 앱을 `dev,loadtest` profile로 재기동합니다. username/password는 앱의 Parameter Store 연동이 loadtest 경로에서 읽습니다.

Start workflow는 load-generator EC2를 만들지 않습니다. 부하 생성용 EC2는 비용 누수를 막기 위해 Run workflow에서만 생성합니다.

## Load Test Run

GitHub에서 **Actions > Load Test Run**을 수동 실행합니다.

입력값:

- `vus`: k6 virtual user 수입니다. 예: `10`
- `iterations`: VU당 반복 횟수입니다. 예: `10`
- `max_duration`: 최대 실행 시간입니다. 예: `30s`, `5m`, `15m`, `1h`
- `test_mode`: 실행할 k6 테스트 모드입니다.
  - `bruno-all-apis`: `solid-connection/api-docs`의 Bruno 문서를 읽어 전체 API 요청용 k6 스크립트를 생성해 실행합니다.
  - `whole-user-flow`: 기존 수동 작성 시나리오인 `whole-user-flow.js`를 실행합니다.
- `api_docs_ref`
  - `test_mode=bruno-all-apis`일 때 checkout할 `solid-connection/api-docs`의 git ref입니다.
  - 기본값은 `main`입니다.
- `target_base_url`
  - 선택값입니다. 비워두면 Terraform output `load_test_target_base_url`을 사용합니다.
- `prometheus_remote_write_url`
  - 선택값입니다. 비워두면 Terraform output `k6_prometheus_remote_write_url`을 사용합니다.
  - Terraform output도 비어 있으면 Prometheus remote-write 전송은 비활성화됩니다.
- `destroy_runner`: `true` 또는 `false`
  - 기본값은 `true`입니다.
  - `true`이면 k6 실행이 끝난 뒤 load-generator EC2를 제거합니다.
  - `false`이면 디버깅이나 재실행을 위해 load-generator EC2를 남깁니다.
- `rebuild_k6`: `true` 또는 `false`
  - 기본값은 `false`입니다.
  - `true`이면 실행 전 기존 k6 binary를 지우고 `set_up_xk6.sh`로 다시 빌드합니다.

Run workflow 동작:

1. `scripts/load_test/run_k6.sh`가 Terraform target apply로 load-generator EC2와 보안 그룹을 생성합니다.
2. Terraform output에서 load-generator EC2 ID와 k6 기본값을 읽습니다.
3. load-generator EC2의 SSM agent가 online 상태가 될 때까지 기다립니다.
4. `test_mode=bruno-all-apis`이면 `solid-connection/api-docs`를 checkout하고 Bruno collection에서 `bruno-all-apis.js`를 생성합니다.
5. SSM RunCommand로 k6 파일을 load-generator EC2에 동기화합니다.
6. 이전 실행에서 남아 있을 수 있는 k6 프로세스를 정리합니다.
7. k6 binary가 없거나 `rebuild_k6=true`이면 `set_up_xk6.sh`로 Prometheus remote-write 지원이 포함된 k6를 빌드합니다.
8. load-generator EC2에서 선택한 k6 스크립트를 실행합니다.
9. `destroy_runner=true`이면 실행 성공/실패와 관계없이 load-generator EC2와 보안 그룹을 제거합니다.

`destroy_runner=false`로 runner를 남긴 뒤 다시 Run workflow를 실행해도 됩니다. 이 경우 기존 EC2를 재사용하며, k6 파일은 매번 다시 동기화됩니다.

동기화되는 k6 파일:

- `createPost.json`
- `updatePost.json`
- `whole-user-flow.js`
- `set_up_xk6.sh`
- `bruno-all-apis.js` (`test_mode=bruno-all-apis` 실행 중 생성)

### Bruno 전체 API 모드

`test_mode=bruno-all-apis`는 Bruno 문서의 `.bru` 파일을 파싱해서 전체 API 요청용 k6 스크립트를 생성합니다.

생성 스크립트의 동작:

- `/auth/email/sign-in`으로 먼저 로그인한 뒤 `auth: inherit` 요청에 bearer token을 붙입니다.
- 기본 로그인 계정은 `user{{VU}}@example.com`, 기본 비밀번호는 `password`입니다.
- `vars:pre-request`, `BASE_URL`, `BRUNO_VAR_*` 환경 변수로 Bruno 변수를 치환합니다.
- Bruno 예시 JSON body와 multipart form body를 요청 본문으로 사용합니다.
- `{{URL}}` 기반의 Solid Connection API만 기본 실행하고, Kakao API 같은 외부 URL은 제외합니다.
- 반복 실행 계정을 제거하는 `/auth/quit`는 기본 실행 대상에서 제외합니다.
- 예시 ID, 권한, 데이터 선행 조건 때문에 4xx 응답은 허용하고, 기본적으로 5xx 응답만 실패 check로 기록합니다.

런타임에서 조정 가능한 k6 환경 변수:

- `BRUNO_ACCESS_TOKEN`: 로그인 대신 이미 발급된 access token을 사용합니다.
- `BRUNO_LOGIN_EMAIL_TEMPLATE`: 로그인 이메일 템플릿입니다. 예: `user{{VU}}@example.com`
- `BRUNO_LOGIN_PASSWORD`: 로그인 비밀번호입니다.
- `BRUNO_REQUEST_SLEEP_SECONDS`: 생성된 요청 사이의 대기 시간입니다.
- `BRUNO_FAIL_ON_5XX`: `false`로 설정하면 5xx 응답도 실패 check로 기록하지 않습니다.
- `BRUNO_VAR_<NAME>`: Bruno 변수 override입니다. 변수명의 영문/숫자가 아닌 문자는 `_`로 바꿔 지정합니다.

## 결과 확인

간단한 실행 결과는 **Load Test Run** GitHub Actions 로그에서 확인합니다.

k6 스크립트는 remote-write URL이 설정된 경우 Prometheus remote-write로도 지표를 전송합니다.

- 기본 remote-write URL은 Terraform output `k6_prometheus_remote_write_url`을 사용합니다.
- Terraform 기본값은 비어 있으므로, 전송이 필요하면 Terraform 변수나 workflow 입력값 `prometheus_remote_write_url`로 URL을 넣습니다.
- k6 지표에는 요청 수, 실패율, 응답 시간, p90, p95, p99, 평균, 최소, 최대값이 포함됩니다.
- API 호출에는 `name`, `testid`, `time` tag가 붙어 endpoint와 실행 시점별로 필터링할 수 있습니다.

## Load Test Stop

GitHub에서 **Actions > Load Test Stop**을 수동 실행합니다.

입력값:

- `restore_stage_dev`: `true` 또는 `false`
  - `true`이면 stage 앱을 기존 dev compose 구성으로 되돌립니다.
- `destroy_infra`: `true` 또는 `false`
  - `true`이면 load-test Terraform stack을 destroy합니다.

Stop workflow 동작:

1. `scripts/load_test/stop.sh`가 `environment/load_test`에서 Terraform init을 실행합니다.
2. `restore_stage_dev=true`이면 stage를 dev datasource 구성으로 복구합니다.
3. `destroy_infra=true`이면 Terraform destroy로 load-test MySQL EC2, 데이터 EBS 볼륨, 보안 그룹과 남아 있는 load-generator EC2를 제거합니다.

## 참고

- GitHub Actions는 OIDC로 AWS role을 assume합니다.
- private submodule checkout에는 `GH_PAT`를 사용합니다.
- prod/stage EC2는 `Name` tag로 조회합니다.
- prod/load-test DB 계정 정보는 Parameter Store에서 읽습니다.
- load-test MySQL EC2 보안 그룹은 prod/stage API EC2 보안 그룹에서 들어오는 MySQL 접근만 허용합니다.
- Load-test DB defaults updated after PR review:
  - `load_test_db_ami_id`: `ami-0501a03cd31b53e82` (`solid-connection-db-mysql-8.4.8-arm64-ubuntu24.04-awscli-recovery-tools`).
  - `load_test_db_instance_type`: `t4g.medium`, matching the arm64 DB AMI family.
  - `load_test_db_subnet_id`: when omitted, the prod DB subnet is used so the existing S3 Gateway Endpoint route is available.
  - `load_test_db_associate_public_ip`: remains `false`; SSM access is provided through Terraform-managed SSM interface endpoints.
  - `load_test_db_instance_profile_name`: defaults to the pre-created dedicated `solid-connection-load-test-db` instance profile. Terraform does not create IAM resources.
  - `load_test_db_port`: defaults to `3306` and is used by the security group, Docker port mapping, Terraform output, and datasource URL.
