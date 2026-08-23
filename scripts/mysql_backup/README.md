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
- API EC2 보안 그룹은 DB EC2 전용 클라이언트 보안 그룹에서 오는 요청만 이 포트들로 허용합니다. 서브넷을 소스로 두지 않으므로 같은 서브넷의 다른 인스턴스는 접근할 수 없습니다.
- 알림 전송 실패는 백업 자체를 실패시키지 않고 로그로만 남깁니다.

### 사용하는 포트

포트는 `config/secrets/prod_db.tfvars`를 단일 원천으로 두고, 보안 그룹과 배포 워크플로우가 같은 값을 읽습니다.

| tfvars 변수 | 값 | 용도 |
|-------------|-----|------|
| `internal_alarm_api_ports` | `[8080, 9080]` | 알림 경로 `POST /internal/alarms/db-backup` 호출 |
| `internal_alarm_api_management_ports` | `[8081, 9081]` | 설치 검증에서 `GET /actuator/health` 확인 |

management 포트는 app 포트에서 규칙으로 유도하지 않고 별도 변수로 둡니다. 두 포트의 관계가 바뀌어도 한쪽만 고치면 되기 때문입니다.

### 설치 검증이 확인하는 것

TCP 연결만으로는 애플리케이션이 기동했는지, 알림 경로가 배포되었는지 알 수 없으므로 두 단계로 확인합니다.

1. management 포트의 `/actuator/health`가 `"status":"UP"`을 반환하는지 확인합니다. 애플리케이션 기동 여부를 확인합니다.
2. 잘못된 토큰으로 알림 경로를 호출해 `401`이 오는지 확인합니다. 경로가 배포되지 않았다면 `404`가 오므로 배포 여부를 구분할 수 있습니다.

토큰 값이 실제로 맞는지는 알림을 발생시키지 않고 확인할 수 없어 검증 대상에서 제외합니다. 알림 경로는 `@Valid`가 먼저 동작해 본문이 잘못되면 토큰 검사 전에 `400`을 반환하므로, 검증 요청은 형식이 올바른 본문에 잘못된 토큰만 담아 보냅니다.

알림 유형:

| 유형 | 발생 조건 |
|------|-----------|
| `DUMP_FAILED` | 여유 공간 부족, mysqldump 실패, 복구 기준점 누락, dump 업로드 실패 |
| `BINLOG_UPLOAD_FAILED` | binlog 회전 실패, binlog 업로드 실패 |
| `BINLOG_GAP_DETECTED` | binlog 번호 불연속, 번호 역행, 닫힌 파일 누락 |
| `BINLOG_UPLOAD_DELAYED` | 마지막 성공 업로드가 900초(타이머 3주기)를 초과 |

`BINLOG_UPLOAD_DELAYED`의 임계값을 타이머 주기와 같은 300초로 두면 정상 동작 중에도 경계에서 매번 지연으로 판정되므로 3주기인 900초를 사용합니다. 판정은 binlog 작업이 실행되는 시점에 이루어지므로 실제 알림은 다음 실행에서 발생할 수 있습니다.

`BINLOG_UPLOAD_DELAYED`는 스크립트가 실행되고 있을 때만 감지할 수 있습니다. EC2나 타이머 자체가 멈춘 경우는 감지할 수 없으므로 S3의 마지막 객체 시각을 외부에서 관찰하는 모니터링이 별도로 필요합니다.

### 알림 인증 토큰

호출자 인증 토큰은 두 곳에서 읽습니다. 각 구성 요소가 자기 설정 체계를 따르므로 값 자체는 두 곳에 존재합니다.

| 사용처 | 위치 |
|--------|------|
| DB EC2의 백업 스크립트 | `config/secrets/prod_db.tfvars`의 `mysql_backup_fail_alarm_request_token` |
| API 서버 | Parameter Store의 `/solid-connection/{env}/internal-alarm.token` |

배포 워크플로우가 secrets submodule에서 값을 읽어 DB EC2의 `/etc/solid-connection/mysql-backup.env`에 기록하므로, 스크립트 쪽 값을 바꿀 때 Terraform apply는 필요하지 않습니다.

### 토큰 회전 절차

두 곳의 값이 어긋나면 모든 알림이 401로 거부되므로 다음 순서를 지킵니다.

1. Parameter Store의 `/solid-connection/{env}/internal-alarm.token`을 새 값으로 변경합니다.
2. API 서버를 재배포해 새 토큰을 읽게 합니다.
3. `config/secrets/prod_db.tfvars`의 `mysql_backup_fail_alarm_request_token`을 같은 값으로 변경하고 커밋합니다.
4. `MySQL Backup Deploy` 워크플로우를 `install`로 실행해 DB EC2의 환경 파일을 갱신합니다.

2번과 4번 사이에는 API 서버가 새 토큰을, DB EC2가 이전 토큰을 사용하므로 알림이 거부됩니다. 1번만 수행한 시점에는 API 서버가 아직 이전 토큰을 들고 있어 알림이 정상 동작합니다. 백업 자체는 회전 중에도 계속 동작하며, 회전은 백업 실패가 없는 시점에 수행합니다.

## dump 실패 처리

- dump 실행 직전에 예상 dump 크기의 2배와 256MiB의 여유 공간을 확인합니다.
- 실패한 작업은 10분 간격으로 최대 3회 다시 시도합니다.
- 6시간을 초과한 작업은 staging과 포인터를 폐기하고 새 dump를 생성합니다.
- 이미 완성된 dump가 남아 있으면 재생성하지 않고 S3 업로드만 다시 시도합니다.
