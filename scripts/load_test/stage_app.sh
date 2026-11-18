#!/usr/bin/env bash
# Sent to the stage instance through SSM by start.sh and stop.sh.
set -euo pipefail

: "${STAGE_MODE:?}"
: "${STAGE_APP_DIR:?}"
: "${STAGE_COMPOSE_FILE:?}"

if [[ "$STAGE_MODE" != "loadtest" && "$STAGE_MODE" != "dev" ]]; then
  echo "Unknown stage mode: $STAGE_MODE" >&2
  exit 1
fi

cd "$STAGE_APP_DIR"
upstream_file="${STAGE_UPSTREAM_FILE:-/etc/nginx/conf.d/upstream.conf}"
if [[ ! -r "$upstream_file" || ! -f "$STAGE_COMPOSE_FILE" ]]; then
  echo "Stage upstream or Compose file is unavailable" >&2
  exit 1
fi

servers=()
while IFS= read -r server; do
  servers+=("$server")
done < <(awk '
  /^[[:space:]]*upstream[[:space:]]+app_backend[[:space:]]*\{/ { in_backend = 1; next }
  in_backend && /^[[:space:]]*\}/ { exit }
  in_backend && /^[[:space:]]*server[[:space:]]/ { print }
' "$upstream_file")
server_pattern='^[[:space:]]*server[[:space:]]+127\.0\.0\.1:(8080|9080);[[:space:]]*$'
if (( ${#servers[@]} != 1 )) || [[ ! "${servers[0]}" =~ $server_pattern ]]; then
  echo "Expected exactly one active 127.0.0.1:8080 or :9080 upstream" >&2
  exit 1
fi

app_port="${BASH_REMATCH[1]}"
if [[ "$app_port" == "8080" ]]; then
  slot="blue"
  management_port="8081"
else
  slot="green"
  management_port="9081"
fi

container="solid-connection-dev-$slot"
project="$container"
if ! app_running="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)"; then
  echo "Active slot container is unavailable: $container" >&2
  exit 1
fi
if [[ "$app_running" != "true" && ( "$STAGE_MODE" != "dev" || "$app_running" != "false" ) ]]; then
  echo "Active slot container is unavailable: $container" >&2
  exit 1
fi
if [[ "$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$container")" != "$project" ]]; then
  echo "Active slot container has the wrong Compose project: $container" >&2
  exit 1
fi

current_image="$(docker inspect -f '{{.Config.Image}}' "$container")"
container_env="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container")"
initial_profile=""
while IFS= read -r env_entry; do
  if [[ "$env_entry" == SPRING_PROFILES_ACTIVE=* ]]; then
    initial_profile="${env_entry#SPRING_PROFILES_ACTIVE=}"
  fi
done <<< "$container_env"
image_pattern='^ghcr\.io/([^/]+)/solid-connection-dev:([^:]+)$'
if [[ ! "$current_image" =~ $image_pattern ]]; then
  echo "Cannot infer the active app image from $current_image" >&2
  exit 1
fi
owner="${BASH_REMATCH[1]}"
image_tag="${BASH_REMATCH[2]}"

mysql_container="solid-connection-dev-mysql"
mysql_project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$mysql_container")"
if [[ -z "$mysql_project" || "$mysql_project" == "<no value>" ]]; then
  echo "Cannot identify the stage MySQL Compose project" >&2
  exit 1
fi
if [[ "$STAGE_MODE" == "loadtest" && "$(docker inspect -f '{{.State.Running}}' "$mysql_container")" != "true" ]]; then
  echo "Stage MySQL must be running before the load-test switch" >&2
  exit 1
fi

override_file="$(mktemp "$STAGE_APP_DIR/.docker-compose.loadtest.XXXXXX")"
trap 'rm -f "$override_file"' EXIT
cat > "$override_file" <<'YAML'
services:
  solid-connection-dev:
    environment:
      SPRING_PROFILES_ACTIVE: dev,loadtest
YAML

recreate_app() {
  local profile="$1"
  local files=(-f "$STAGE_COMPOSE_FILE")
  if [[ "$profile" == "loadtest" ]]; then
    files+=(-f "$override_file")
  fi
  SLOT="$slot" APP_PORT="$app_port" MANAGEMENT_PORT="$management_port" \
    OWNER_LOWERCASE="$owner" IMAGE_TAG="$image_tag" \
    docker compose -p "$project" "${files[@]}" up -d --no-deps --force-recreate solid-connection-dev
}

wait_for_app() {
  local attempt
  for (( attempt = 1; attempt <= ${STAGE_HEALTH_ATTEMPTS:-30}; attempt++ )); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${management_port}/actuator/health" >/dev/null; then
      return 0
    fi
    sleep "${STAGE_HEALTH_INTERVAL_SECONDS:-5}"
  done
  return 1
}

wait_for_mysql() {
  local attempt
  for (( attempt = 1; attempt <= ${STAGE_MYSQL_ATTEMPTS:-30}; attempt++ )); do
    if docker exec "$mysql_container" mysqladmin ping -h 127.0.0.1 --silent >/dev/null 2>&1; then
      return 0
    fi
    sleep "${STAGE_HEALTH_INTERVAL_SECONDS:-5}"
  done
  return 1
}

dev_recreate_started=false
restore_dev() {
  docker compose -p "$mysql_project" -f "$STAGE_COMPOSE_FILE" start mysql || return 1
  wait_for_mysql || return 1
  dev_recreate_started=true
  recreate_app dev && wait_for_app
}

if [[ "$STAGE_MODE" == "loadtest" ]]; then
  if ! recreate_app loadtest || ! wait_for_app ||
      ! docker compose -p "$mysql_project" -f "$STAGE_COMPOSE_FILE" stop mysql ||
      ! wait_for_app; then
    echo "Load-test switch failed; restoring dev in the same slot" >&2
    restore_dev || echo "Stage dev rollback also failed" >&2
    exit 1
  fi
else
  if ! restore_dev; then
    echo "Stage dev restore failed; retaining the load-test DB EC2" >&2
    if [[ "$initial_profile" == "dev,loadtest" &&
          ( "$dev_recreate_started" == "true" || "$app_running" != "true" ) ]]; then
      recreate_app loadtest && wait_for_app &&
        docker compose -p "$mysql_project" -f "$STAGE_COMPOSE_FILE" stop mysql &&
        wait_for_app ||
        echo "Stage load-test rollback also failed" >&2
    fi
    exit 1
  fi
fi
