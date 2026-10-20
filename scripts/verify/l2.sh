#!/usr/bin/env bash
#
# L2 plan 검사: 실제 AWS 상태와 비교한 plan 을 데이터(JSON)로 다뤄 변경 목록/정책/의도를 검사한다.
#
# 필요 조건 (없으면 FAIL 이 아니라 SKIPPED 로 사유를 남긴다)
#   - AWS read-only 자격증명 (~/.aws 또는 환경 변수)
#   - config/secrets submodule (tfvars)
#   - prod: DB EC2 로의 SSM 포트 포워딩 권한 (mysql provider)
#
set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

readonly LAYER=L2
readonly PLAN_DIR=/tmp/verify-plan
readonly OUT_DIR=/out/l2
# 작업 복사본(/work)에는 secrets 가 없으므로 읽기 전용 원본을 참조한다. (verify.sh run_in_container 참고)
readonly SECRETS_DIR=/workspace/config/secrets
readonly SSM_TUNNEL_TIMEOUT=60
readonly STATE_BUCKET=solid-connection-tfstate
SSM_PID=""
TUNNEL_ERROR=""

section "L2 plan 검사"

# CI(.github/workflows/terraform-plan.yml)와 같은 tfvars 조합
var_files_of() {
  case "$1" in
    bootstrap) ;;
    global) echo shared_resources.tfvars ;;
    prod) echo prod.tfvars prod_db.tfvars app_stack.tfvars ;;
    stage) echo stage.tfvars app_stack.tfvars ;;
    monitoring) echo monitoring.tfvars monitoring_stack.tfvars ;;
    load_test) echo load_test.tfvars ;;
  esac
}

dir_of() {
  [[ "$1" == bootstrap ]] && echo bootstrap || echo "environment/$1"
}

# prod 의 mysql provider 는 127.0.0.1:3306 으로 DB EC2 에 접속하므로 CI 와 같은 방식으로 SSM 터널을 연다.
# 터널 프로세스를 이 셸에서 관리해야 하므로 $(...) 로 호출하지 않고, 실패 사유는 TUNNEL_ERROR 에 남긴다.
start_prod_tunnel() {
  local ec2_id db_host
  ec2_id="$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=solid-connection-server-prod" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"
  db_host="$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=solid-connection-db-mysql-prod" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null || true)"
  if [[ -z "$ec2_id" || "$ec2_id" == None || -z "$db_host" || "$db_host" == None ]]; then
    TUNNEL_ERROR="prod EC2/DB EC2 조회 실패 (ec2:DescribeInstances 권한 확인)"
    return 1
  fi

  aws ssm start-session --target "$ec2_id" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "{\"host\":[\"$db_host\"],\"portNumber\":[\"3306\"],\"localPortNumber\":[\"3306\"]}" \
    >/tmp/ssm-tunnel.log 2>&1 &
  SSM_PID=$!

  local _
  for _ in $(seq 1 "$SSM_TUNNEL_TIMEOUT"); do
    if ! kill -0 "$SSM_PID" 2>/dev/null; then
      TUNNEL_ERROR="SSM 세션 종료됨 (ssm:StartSession 권한 확인): $(tail -n1 /tmp/ssm-tunnel.log)"
      return 1
    fi
    nc -z 127.0.0.1 3306 2>/dev/null && return 0
    sleep 1
  done
  TUNNEL_ERROR="${SSM_TUNNEL_TIMEOUT}초 내에 터널이 준비되지 않음"
  return 1
}

stop_prod_tunnel() {
  [[ -n "$SSM_PID" ]] && kill "$SSM_PID" 2>/dev/null || true
  SSM_PID=""
}
trap stop_prod_tunnel EXIT

plan_env() {
  local env="$1" dir plan_file
  dir="$(dir_of "$env")"
  plan_file="$PLAN_DIR/$env.tfplan"

  local -a var_args=()
  local f
  for f in $(var_files_of "$env"); do
    var_args+=("-var-file=$SECRETS_DIR/$f")
  done

  # run_check 는 if 문맥에서 실행하므로 set -e 가 적용되지 않는다. 단계마다 실패를 명시적으로 반환한다.
  # 이전 실행의 결과가 남아 다음 검사에 쓰이지 않도록 먼저 지우고, JSON 은 성공했을 때만 최종 경로로 옮긴다.
  rm -f "$plan_file" "$PLAN_DIR/$env.json" "$PLAN_DIR/$env.json.tmp"
  terraform -chdir="$dir" init -input=false -reconfigure -no-color >"$OUT_DIR/$env.init.txt" 2>&1 \
    || { cat "$OUT_DIR/$env.init.txt"; return 1; }
  terraform -chdir="$dir" plan -input=false -no-color -lock-timeout=60s -out="$plan_file" "${var_args[@]}" \
    >"$OUT_DIR/$env.plan.txt" 2>&1 || { cat "$OUT_DIR/$env.plan.txt"; return 1; }
  terraform -chdir="$dir" show -json "$plan_file" >"$PLAN_DIR/$env.json.tmp" || return 1
  mv "$PLAN_DIR/$env.json.tmp" "$PLAN_DIR/$env.json"
}

if [[ -n "${VERIFY_L2_DETECT_ERROR:-}" ]]; then
  record SKIPPED "$LAYER" "L2 대상 감지" "$VERIFY_L2_DETECT_ERROR"
  exit 0
fi

read -r -a envs <<<"${VERIFY_L2_ENVS:-}"

# 환경별 intent 는 자기 환경 줄만 대조하므로, plan 대상이 아닌 환경에 선언한 의도는 따로 확인한다.
# 자동 감지일 때 선언 환경이 대상이 아니면 그 환경 코드가 바뀌지 않은 것이므로 FAIL,
# --env 로 일부만 지정했다면 나머지는 검사하지 않은 것이므로 SKIPPED 로 남긴다.
if [[ -n "${VERIFY_EXPECT:-}" ]]; then
  env_check_rc=0
  env_check_out="$(python3 scripts/verify/plan_check.py check-envs --expect "$VERIFY_EXPECT" --planned "${envs[@]}" 2>&1)" \
    || env_check_rc=$?
  if [[ "$env_check_rc" -eq 0 ]]; then
    record PASS "$LAYER" "intent (declared envs)"
  elif [[ "$env_check_rc" -eq 3 && "${VERIFY_L2_AUTO:-false}" != true ]]; then
    record SKIPPED "$LAYER" "intent (declared envs)" "$(tr '\n' ' ' <<<"$env_check_out")"
  else
    record FAIL "$LAYER" "intent (declared envs)"
    sed 's/^/    | /' <<<"$env_check_out"
  fi
fi

if [[ ${#envs[@]} -eq 0 ]]; then
  echo "  변경된 Terraform 환경이 없어 L2 대상이 없습니다. (--env 로 직접 지정 가능)"
  exit 0
fi

mkdir -p "$PLAN_DIR" "$OUT_DIR"

# 자격증명이 있어도 다른 계정(개인/타 조직 profile)일 수 있으므로 state 버킷 접근으로 확인한다.
credential_error=""
if ! aws_identity="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"; then
  credential_error="AWS 자격증명 없음 또는 만료 (AWS_PROFILE 확인)"
elif ! aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; then
  credential_error="현재 자격증명($aws_identity)으로 $STATE_BUCKET 에 접근 불가 (AWS_PROFILE=solid-connection-readonly 확인)"
else
  echo "  AWS 자격증명: $aws_identity"
fi

for env in "${envs[@]}"; do
  if [[ -n "$credential_error" ]]; then
    record SKIPPED "$LAYER" "plan ($env)" "$credential_error"
    continue
  fi

  missing=""
  for f in $(var_files_of "$env"); do
    [[ -f "$SECRETS_DIR/$f" ]] || missing="$missing $f"
  done
  if [[ -n "$missing" ]]; then
    record SKIPPED "$LAYER" "plan ($env)" "tfvars 없음:$missing (git submodule update --init --recursive)"
    continue
  fi

  if [[ "$env" == prod ]]; then
    if ! start_prod_tunnel; then
      stop_prod_tunnel
      record SKIPPED "$LAYER" "plan ($env)" "DB SSM 터널 실패: $TUNNEL_ERROR"
      continue
    fi
  fi

  run_check "$LAYER" "plan ($env)" plan_env "$env"
  [[ "$env" == prod ]] && stop_prod_tunnel

  if [[ ! -f "$PLAN_DIR/$env.json" ]]; then
    continue
  fi
  # summary 는 표시용이다. 실패(미지원 action 등)해도 아래 policy/intent 와 다음 환경 검사는 계속한다.
  python3 scripts/verify/plan_check.py summary "$PLAN_DIR/$env.json" || true
  run_check "$LAYER" "policy ($env)" python3 scripts/verify/plan_check.py policy "$PLAN_DIR/$env.json"
  if [[ -n "${VERIFY_EXPECT:-}" ]]; then
    run_check "$LAYER" "intent ($env)" \
      python3 scripts/verify/plan_check.py expect "$PLAN_DIR/$env.json" --env "$env" --expect "$VERIFY_EXPECT"
  else
    record SKIPPED "$LAYER" "intent ($env)" "의도 파일 미지정 (--expect)"
  fi
done

# 호스트 사용자 소유로 돌려준다. (Linux 에서 root 소유 파일이 남지 않게)
[[ -n "${HOST_UID:-}" ]] && chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" /out 2>/dev/null || true
echo "  plan 전문: .verify/l2/<env>.plan.txt"
