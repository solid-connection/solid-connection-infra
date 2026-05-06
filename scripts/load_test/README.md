# 부하 테스트 자동화

부하 테스트용 임시 RDS와 k6 전용 EC2를 생성하고, prod RDS 데이터를 복사한 뒤 stage 서버가 loadtest datasource를 바라보도록 전환하는 자동화입니다. 시작, 실행, 종료는 GitHub Actions에서 수동으로 실행합니다.

## secret에 필요한 값

EC2 기반 k6 실행을 위해 새로 `config/secrets/load_test.tfvars`에 추가해야 하는 값은 없습니다.

기존 loadtest Terraform에 필요한 민감값만 secret에 둡니다.

- `load_test_db_username_parameter_name`
- `load_test_db_password_parameter_name`

아래 값들은 민감값이 아니므로 secret에 넣지 않고 Terraform 기본값이나 GitHub Actions 입력값으로 처리합니다.

- k6 전용 EC2 instance type: 기본값 `c7i.xlarge`
- k6 전용 EC2 IAM instance profile 이름: 기본값 `solid-connection-load-test-generator`
- k6 target URL: 기본값 `https://api.stage.solid-connection.com`
- k6 VU, iterations, max duration: **Load Test Run** workflow 입력값
- Prometheus remote-write URL: 기본값 사용 또는 **Load Test Run** workflow 입력값

기본 instance profile 이름을 쓰지 않을 경우 secret이 아니라 GitHub Actions variable 또는 `TF_VAR_load_generator_instance_profile_name`으로 덮어씁니다.

## 원칙

- 사람이 로컬에서 `terraform apply` 또는 `terraform destroy`를 직접 실행하지 않습니다.
- stage EC2는 부하를 받는 대상이므로 stage EC2에서 k6를 실행하지 않습니다.
- k6는 loadtest Terraform이 생성한 별도 EC2에서 실행합니다.
- SSH private key는 사용하지 않습니다. stage/prod/load-generator EC2 작업은 SSM RunCommand로 실행합니다.

## 시작

1. GitHub에서 **Actions > Load Test Start**를 엽니다.
2. **Run workflow**를 클릭합니다.
3. 필요한 입력값을 선택하고 실행합니다.

입력값:

- `switch_stage_to_loadtest`: stage 앱을 `dev,loadtest` 프로필로 재기동합니다.
- `copy_prod_data`: prod RDS 데이터를 loadtest RDS로 복사합니다.

workflow는 GitHub Actions runner에서 `environment/load_test`의 Terraform을 apply하고 `scripts/load_test/start.sh`를 실행합니다.

## 시작 시 수행 작업

1. GitHub Actions가 `environment/load_test`에서 Terraform apply를 실행합니다.
2. loadtest RDS, 보안 그룹, k6 전용 EC2를 생성합니다.
3. loadtest datasource 값을 Parameter Store에 작성합니다.
4. prod DB와 loadtest DB 접속 정보를 Parameter Store에서 읽습니다.
5. SSM RunCommand로 prod EC2에서 `mysqldump`를 실행하고 loadtest RDS로 복원합니다.
6. SSM RunCommand로 stage 앱을 `dev,loadtest` 프로필로 재기동합니다.
7. 데이터 이관용 임시 Parameter Store 값을 삭제합니다.

## 실행

1. GitHub에서 **Actions > Load Test Run**을 엽니다.
2. **Run workflow**를 클릭합니다.
3. VU, iterations, max duration을 입력하고 실행합니다.

workflow는 `scripts/load_test/run_k6.sh`를 실행합니다.

실행 시 수행 작업:

1. Terraform output에서 k6 전용 EC2 ID와 기본 실행값을 읽습니다.
2. SSM RunCommand로 k6 파일을 k6 전용 EC2에 배치합니다.
3. k6 전용 EC2에서 `set_up_xk6.sh`로 k6 binary를 준비합니다.
4. k6 전용 EC2에서 `whole-user-flow.js`를 실행합니다.

## 종료

1. GitHub에서 **Actions > Load Test Stop**을 엽니다.
2. **Run workflow**를 클릭합니다.
3. 필요한 입력값을 선택하고 실행합니다.

입력값:

- `restore_stage_dev`: stage 앱을 기존 dev compose 구성으로 되돌립니다.
- `destroy_rds`: loadtest Terraform stack을 제거합니다.

workflow는 `scripts/load_test/stop.sh`를 실행하고, 선택값에 따라 stage 복구와 Terraform destroy를 수행합니다. Terraform destroy에는 loadtest RDS와 k6 전용 EC2 제거가 포함됩니다.

## k6 파일

포함 파일:

- `createPost.json`
- `updatePost.json`
- `whole-user-flow.js`
- `set_up_xk6.sh`
- `script/set-load-test.sh`

이 파일들은 stage EC2가 아니라 k6 전용 EC2에 동기화됩니다.

## 참고

- GitHub Actions는 OIDC로 `AWS_ROLE_ARN`을 assume합니다.
- private submodule checkout에는 `GH_PAT`를 사용합니다.
- prod/stage EC2는 `Name` tag로 조회합니다.
- prod/loadtest DB username/password는 Parameter Store에서 읽습니다.
- loadtest RDS security group은 prod/stage API EC2 security group에서 오는 MySQL 접근만 허용합니다.
