# Prod MySQL S3 백업

DB EC2에서 다음 systemd 작업을 실행합니다.

- `mysql-backup-dump.timer`: 매일 03:00 KST에 일관된 전체 dump, 체크섬, manifest를 업로드합니다.
- `mysql-backup-binlog.timer`: 매 5분 경계마다 binlog를 회전하고 닫힌 파일과 manifest를 업로드합니다.

백업 파일은 `/mnt/mysql-data/mysql-backup`에서만 임시 생성합니다. S3에는 manifest를 마지막에 업로드하며, 같은 key가 이미 존재하면 체크섬이 같은 경우에만 업로드를 생략합니다. 이 방식으로 재시도 시 Object Lock 버킷에 불필요한 객체 버전이 생기는 것을 방지합니다.

## 배포 전 GitHub 설정

Repository Secrets:

- `AWS_ROLE_ARN`: 배포 워크플로우가 AssumeRole할 IAM 역할 ARN

Repository Variables:

- `MYSQL_BACKUP_BUCKET_NAME`: 백업 버킷 이름
- `MYSQL_BACKUP_DATABASE_NAME`: 백업할 DB 이름. 필수값이며 공개 코드에 기본값을 두지 않습니다.
- `PROD_DB_SSH_HOST_KEY_ED25519`: DB EC2의 ED25519 host key SHA-256 fingerprint

GitHub Environment:

- `prod-db`: required reviewer, self-review 차단, `main` 배포 브랜치 제한을 적용합니다.

> `MySQL Backup Deploy` 워크플로우는 `main` 브랜치에서만 실행되며, `prod-db` 승인을 통과해야 합니다. 기본값인 `validate`는 변경 없이 사전 조건 또는 설치 상태만 검사하고, 실제 설치는 `install`을 명시적으로 선택해야 합니다.

`MySQL Backup Test` 워크플로우는 AWS 권한이나 운영 환경 접근 없이 백업 스크립트 단위 테스트를 수동으로 실행합니다.

## dump 실패 처리

- dump 실행 직전에 예상 dump 크기의 2배와 256MiB의 여유 공간을 확인합니다.
- 실패한 작업은 10분 간격으로 최대 3회 다시 시도합니다.
- 6시간을 초과한 작업은 staging과 포인터를 폐기하고 새 dump를 생성합니다.
- 이미 완성된 dump가 남아 있으면 재생성하지 않고 S3 업로드만 다시 시도합니다.
