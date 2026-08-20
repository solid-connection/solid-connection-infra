# Prod MySQL S3 백업

DB EC2에서 다음 systemd 작업을 실행합니다.

- `mysql-backup-dump.timer`: 매일 03:00 KST에 일관된 전체 dump, 체크섬, manifest를 업로드합니다.
- `mysql-backup-binlog.timer`: 매 5분 경계마다 binlog를 회전하고 닫힌 파일과 manifest를 업로드합니다.

백업 파일은 `/mnt/mysql-data/mysql-backup`에서만 임시 생성합니다. S3에는 manifest를 마지막에 업로드하며, 같은 key가 이미 존재하면 체크섬이 같은 경우에만 업로드를 생략합니다. 이 방식으로 재시도 시 Object Lock 버킷에 불필요한 객체 버전이 생기는 것을 방지합니다.

## 배포 전 GitHub 설정

Repository Secrets:

- `AWS_ROLE_ARN`: 배포 워크플로우가 AssumeRole할 IAM 역할 ARN
- `GH_PAT`: secrets submodule을 체크아웃할 토큰
- `MYSQL_BACKUP_BUCKET_NAME`: 백업 버킷 이름
- `MYSQL_BACKUP_DATABASE_NAME`: 백업할 DB 이름. 필수값이며 공개 코드에 기본값을 두지 않습니다.
- `PROD_DB_SSH_HOST_KEY_ED25519`: DB EC2의 ED25519 host key SHA-256 fingerprint

GitHub Environment:

- `prod-db`: required reviewer, self-review 차단, `main` 배포 브랜치 제한을 적용합니다.

> `MySQL Backup Deploy` 워크플로우는 `main` 브랜치에서만 실행되며, `prod-db` 승인을 통과해야 합니다. 기본값인 `validate`는 변경 없이 사전 조건 또는 설치 상태만 검사하고, 실제 설치는 `install`을 명시적으로 선택해야 합니다.

`MySQL Backup Test` 워크플로우는 AWS 권한이나 운영 환경 접근 없이 백업 스크립트 단위 테스트를 수동으로 실행합니다.

## 백업 실패 알림

백업이 실패하거나 지연되면 API 서버의 내부 전용 API를 거쳐 Discord로 알립니다.

```text
DB EC2 (private subnet, 인터넷 경로 없음)
└─ 백업 실패 감지
   └─ POST http://<API EC2 private ip>:<8080 또는 9080>/internal/alarms/db-backup
      └─ API 서버 → Discord Webhook
```

- DB EC2가 있는 서브넷의 라우팅 테이블에는 NAT와 IGW가 없어 Discord를 직접 호출할 수 없으므로 API 서버가 중계합니다.
- Blue/Green 활성 슬롯을 알 수 없으므로 두 슬롯의 app 포트를 순서대로 시도하고 먼저 응답한 쪽으로 보냅니다.
- API EC2 보안 그룹은 이 두 포트를 DB EC2 서브넷에서만 허용합니다.
- 알림 전송 실패는 백업 자체를 실패시키지 않고 로그로만 남깁니다.

알림 유형:

| 유형 | 발생 조건 |
|------|-----------|
| `DUMP_FAILED` | 여유 공간 부족, mysqldump 실패, 복구 기준점 누락, dump 업로드 실패 |
| `BINLOG_UPLOAD_FAILED` | binlog 회전 실패, binlog 업로드 실패 |
| `BINLOG_GAP_DETECTED` | binlog 번호 불연속, 번호 역행, 닫힌 파일 누락 |
| `BINLOG_UPLOAD_DELAYED` | 마지막 성공 업로드가 5분을 초과 |

`BINLOG_UPLOAD_DELAYED`는 스크립트가 실행되고 있을 때만 감지할 수 있습니다. EC2나 타이머 자체가 멈춘 경우는 감지할 수 없으므로 S3의 마지막 객체 시각을 외부에서 관찰하는 모니터링이 별도로 필요합니다.

### 알림 인증 토큰

호출자 인증 토큰은 `config/secrets/prod_db.tfvars`의 `mysql_backup_fail_alarm_request_token`을 단일 원천으로 사용합니다. 배포 워크플로우가 secrets submodule에서 값을 읽어 DB EC2의 `/etc/solid-connection/mysql-backup.env`에 기록하므로, 토큰을 변경할 때 Terraform apply 없이 배포 워크플로우만 다시 실행하면 됩니다.

> API 서버는 같은 토큰을 Parameter Store의 `/solid-connection/{env}/internal-alarm.token`에서 읽습니다. 토큰을 회전할 때 두 곳을 함께 변경해야 하며, 한쪽만 변경하면 모든 알림이 401로 거부됩니다.

## dump 실패 처리

- dump 실행 직전에 예상 dump 크기의 2배와 256MiB의 여유 공간을 확인합니다.
- 실패한 작업은 10분 간격으로 최대 3회 다시 시도합니다.
- 6시간을 초과한 작업은 staging과 포인터를 폐기하고 새 dump를 생성합니다.
- 이미 완성된 dump가 남아 있으면 재생성하지 않고 S3 업로드만 다시 시도합니다.
