# 부하 테스트 자동화

부하 테스트용 임시 RDS를 생성하고, prod RDS 데이터를 복사한 뒤 stage 서버가 loadtest datasource를 바라보도록 전환하는 자동화입니다. 시작과 종료는 GitHub Actions에서 수동으로 실행합니다.

## 원칙

- 사람이 로컬에서 `terraform apply` 또는 `terraform destroy`를 직접 실행하지 않습니다.
- 시작은 **Actions > Load Test Start** workflow로 실행합니다.
- 종료는 **Actions > Load Test Stop** workflow로 실행합니다.
- SSH private key는 사용하지 않습니다. stage/prod EC2 작업은 SSM RunCommand로 실행합니다.

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
2. loadtest RDS와 보안 그룹을 생성합니다. RDS는 stage EC2가 속한 VPC/subnet 기준으로 생성됩니다.
3. loadtest datasource 값을 Parameter Store에 작성합니다.
4. prod DB와 loadtest DB 접속 정보를 Parameter Store에서 읽습니다.
5. SSM RunCommand로 prod EC2에서 `mysqldump`를 실행하고 loadtest RDS로 복원합니다.
6. stage EC2에 k6 파일을 `/home/ubuntu/solid-connection-load-test/k6` 경로로 동기화합니다.
7. SSM RunCommand로 stage 앱을 `dev,loadtest` 프로필로 재기동합니다.
8. 데이터 이관용 임시 Parameter Store 값을 삭제합니다.

## 종료

1. GitHub에서 **Actions > Load Test Stop**을 엽니다.
2. **Run workflow**를 클릭합니다.
3. 필요한 입력값을 선택하고 실행합니다.

입력값:

- `restore_stage_dev`: stage 앱을 기존 dev compose 구성으로 되돌립니다.
- `destroy_rds`: loadtest Terraform stack을 제거합니다.

workflow는 `scripts/load_test/stop.sh`를 실행하고, 선택값에 따라 stage 복구와 Terraform destroy를 수행합니다.

## k6 파일

stage EC2를 새로 생성하는 경우 Terraform cloud-init이 k6 파일을 배치합니다. 기존 stage EC2는 cloud-init이 다시 실행되지 않으므로, **Load Test Start** workflow가 실행될 때 SSM으로 k6 파일을 다시 동기화합니다.

포함 파일:

- `createPost.json`
- `updatePost.json`
- `whole-user-flow.js`
- `set_up_xk6.sh`
- `script/set-load-test.sh`

stage EC2에 접속해 수동으로 실행해야 한다면 다음 경로에서 실행합니다.

```bash
cd /home/ubuntu/solid-connection-load-test/k6
./set_up_xk6.sh
./script/set-load-test.sh
```

## 참고

- GitHub Actions는 OIDC로 `AWS_ROLE_ARN`을 assume합니다.
- private submodule checkout에는 `GH_PAT`를 사용합니다.
- prod/stage EC2는 `Name` tag로 조회합니다.
- prod/loadtest DB username/password는 Parameter Store에서 읽습니다.
- loadtest RDS security group은 prod/stage API EC2 security group에서 오는 MySQL 접근만 허용합니다.
