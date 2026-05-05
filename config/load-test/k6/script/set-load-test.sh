#!/usr/bin/env bash
set -euo pipefail

# 작업 디렉터리 설정
WORKDIR="/home/ubuntu"

#######################################################################
#  set-load-test.sh
#  사용 예: SQL_FILE_BASENAME=regular.sql ./set-load-test.sh
#######################################################################

# 0. 필수 값 검증
SQL_BASENAME="${SQL_FILE_BASENAME:-regular.sql}"
if [[ -z "$SQL_BASENAME" ]]; then
  echo "❌ 사용할 덤프 파일이 입력되지 않았습니다." >&2
  echo "SQL_FILE_BASENAME={dump 파일 이름} ./set-load-test.sh 형식으로 인자를 전달해야합니다." >&2
  exit 1
fi

SQL_SRC="$WORKDIR/load-test-setting/db/${SQL_BASENAME}"
if [[ ! -f "$SQL_SRC" ]]; then
  echo "❌ 덤프 파일이 파일 시스템에 존재하지 않습니다: $SQL_SRC" >&2
  exit 2
fi

# 1. 기존 어플리케이션, DB 중지
docker compose -f "$WORKDIR/solid-connection-dev/docker-compose.dev.yml" down \
  || { echo "❌ 어플리케이션 도커 중지 실패: $WORKDIR/solid-connection-dev/docker-compose.dev.yml" >&2; exit 3; }
docker compose -f "$WORKDIR/mysql/docker-compose.mysql.yml" down \
  || { echo "❌ MySQL 도커 중지 실패: $WORKDIR/mysql/docker-compose.mysql.yml" >&2; exit 4; }

# 2. 부하 테스트용 DB 실행
docker compose -f "$WORKDIR/load-test-setting/docker-compose.load-test.yml" up -d \
  || { echo "❌ 부하 테스트용 DB 실행 실패: docker-compose.load-test.yml" >&2; exit 5; }

# 3. MySQL 준비 대기 (최대 30초)
CONTAINER_NAME="load-test-db"
echo "⏳ MySQL이 준비될 때까지 대기 중 (최대 30초)..."
start_time=$(date +%s)
while ! docker exec "$CONTAINER_NAME" sh -c 'mysqladmin ping -h "127.0.0.1" --silent'; do
  elapsed=$(( $(date +%s) - start_time ))
  if [[ $elapsed -ge 30 ]]; then
    echo "❌ MySQL 준비 시간 초과 (30초)" >&2
    exit 1
  fi
  printf "."
  sleep 1
done
echo "✔️ MySQL 준비 완료."

# 4. dump 주입
echo "📥 dump 파일 복사 → 컨테이너: $CONTAINER_NAME"
docker cp "$SQL_SRC" "${CONTAINER_NAME}:/tmp/dump.sql" \
  || { echo "❌ dump 복사 실패: $SQL_SRC → $CONTAINER_NAME:/tmp/dump.sql" >&2; exit 6; }

echo "⚙️ dump 이식"
docker exec -i "$CONTAINER_NAME" sh -c 'mysql -u root -proot < /tmp/dump.sql' \
  || { echo "❌ dump 이식 실패: 컨테이너 $CONTAINER_NAME" >&2; exit 7; }

# 5. 어플리케이션 다시 실행
docker compose -f "$WORKDIR/solid-connection-dev/docker-compose.dev.yml" up -d \
  || { echo "❌ 어플리케이션 재시작 실패: $WORKDIR/solid-connection-dev/docker-compose.dev.yml" >&2; exit 8; }

echo "✅ 부하 테스트용 DB에 연결된 어플리케이션 실행 완료!"
