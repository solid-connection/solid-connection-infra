# 부하 테스트 자동화

부하 테스트용 임시 RDS를 생성하고, prod RDS 데이터를 복사한 뒤 stage 서버가
loadtest datasource를 바라보도록 전환하는 자동화입니다. 시작과 종료는 GitHub
Actions에서 수동으로 실행합니다.

## 시작

1. GitHub에서 **Actions > Load Test Start**를 엽니다.
2. **Run workflow**를 클릭합니다.
3. 기본값 그대로 실행합니다.

입력값:

- `switch_stage_to_loadtest`: stage 앱을 `dev,loadtest` 프로필로 재기동합니다.
- `copy_prod_data`: prod RDS 데이터를 loadtest RDS로 복사합니다.

시작 workflow는 `scripts/load_test/start.sh`를 실행합니다.

## 종료

1. GitHub에서 **Actions > Load Test Stop**을 엽니다.
2. **Run workflow**를 클릭합니다.
3. 기본값 그대로 실행합니다.

입력값:

- `restore_stage_dev`: stage 앱을 기존 dev compose 구성으로 되돌립니다.
- `destroy_rds`: loadtest Terraform stack을 제거합니다.

종료 workflow는 `scripts/load_test/stop.sh`를 실행합니다.

## 시작 시 수행 작업

1. `environment/load_test`에서 `terraform apply`를 실행합니다.
2. loadtest RDS를 생성하고 아래 Parameter Store 값을 작성합니다.
   - `/solid-connection/loadtest/spring.datasource.url`
   - `/solid-connection/loadtest/spring.datasource.username`
   - `/solid-connection/loadtest/spring.datasource.password`
3. SSM RunCommand로 stage 앱을 `dev,loadtest` 프로필로 재기동합니다.
4. migration용 임시 Parameter Store 값을 생성합니다.
5. SSM RunCommand로 prod EC2에서 `mysqldump`를 실행하고 loadtest RDS에 복원합니다.
6. migration용 임시 Parameter Store 값을 삭제합니다.

## 종료 시 수행 작업

1. SSM RunCommand로 stage 앱을 기존 dev compose 구성으로 되돌립니다.
2. `environment/load_test`에서 `terraform destroy`를 실행합니다.

## k6 파일

stage EC2를 새로 생성하는 경우 Terraform cloud-init이
`/home/ubuntu/solid-connection-load-test/k6`에 k6 파일을 배치합니다.

현재 포함된 파일:

- `createPost.json`
- `updatePost.json`
- `whole-user-flow.js`
- `set_up_xk6.sh`
- `script/set-load-test.sh`

기존 stage EC2는 재생성하지 않으므로 이 cloud-init 변경이 즉시 반영되지는 않습니다.

## 참고 사항

- GitHub Actions는 OIDC로 `AWS_ROLE_ARN`을 assume합니다.
- private submodule checkout에는 `GH_PAT`를 사용합니다.
- SSH private key는 사용하지 않습니다.
- prod/stage EC2는 `Name` tag로 조회합니다.
- prod DB username/password는 Parameter Store에서 읽습니다.
- loadtest DB username/password도 Parameter Store에서 읽습니다.
- loadtest RDS security group은 prod/stage API EC2 security group에서 오는 MySQL
  접근만 허용합니다.
