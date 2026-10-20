#!/usr/bin/env bash
#
# 인프라 레포 검증 진입점.
#
# 호스트에서 실행하면 검증 이미지를 확인하고(없거나 Dockerfile 이 바뀌었으면 빌드),
# 레포를 읽기 전용으로 마운트한 컨테이너 안에서 이 스크립트를 다시 실행한다.
# 컨테이너 안에서는 레포를 /work 로 복사한 뒤 요청한 계층(L1/L2/L3)을 순서대로 실행한다.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly IMAGE_REPO="solid-connection-verify"
readonly DEFAULT_LAYERS=(l1 l3)
readonly ALL_ENVS=(bootstrap global prod stage monitoring load_test)

usage() {
  cat <<'EOF'
Usage: scripts/verify/verify.sh [LAYER...] [OPTIONS]

LAYER:
  l1        정적 검사 (fmt, validate, tflint, trivy, shellcheck, actionlint)
  l2        plan 검사 (AWS read-only 자격증명, secrets submodule 필요)
  l3        동작 테스트 (템플릿 렌더링 + shellcheck, 스크립트 테스트)
  all       l1 l2 l3
  (생략 시 l1 l3)

OPTIONS:
  --env ENV        L2 대상 환경 (반복 가능, 생략 시 origin/main 대비 변경된 환경 자동 감지)
                   bootstrap | global | prod | stage | monitoring | load_test
  --expect FILE    L2 의도 대조 파일 (권장 위치: .verify/expect.txt, 형식은 scripts/verify/README.md 참고)
  --base REF       L2 변경 감지 기준 ref (기본: origin/main)
  --strict         SKIPPED 도 실패로 처리 (CI 용)
  --rebuild        검증 이미지를 강제로 다시 빌드
  --print-image    사용할 검증 이미지 이름만 출력하고 종료
  -h, --help       도움말
EOF
}

# ---------------------------------------------------------------------------
# 컨테이너 안: 계층 실행
# ---------------------------------------------------------------------------
run_in_container() {
  # 원본(/workspace)은 읽기 전용이다. 검증 중 생기는 .terraform 등은 복사본(/work)에만 남는다.
  # 복사본에는 secrets(tfvars)를 넣지 않는다. L1/L3 는 구조적으로 tfvars 를 읽을 수 없고(CI 와 동일),
  # L2 만 읽기 전용 원본(/workspace/config/secrets)을 -var-file 로 참조한다.
  tar -C /workspace --exclude=.git --exclude=.terraform --exclude=.verify \
    --exclude=./config/secrets --exclude='*.tfvars' -cf - . | tar -C /work -xf -
  mkdir -p "$TF_PLUGIN_CACHE_DIR" "$TRIVY_CACHE_DIR"

  export VERIFY_RESULTS
  VERIFY_RESULTS="$(mktemp)"

  local layer
  for layer in "${LAYERS[@]}"; do
    bash "/work/scripts/verify/${layer}.sh"
  done

  # shellcheck source=lib/common.sh
  source /work/scripts/verify/lib/common.sh
  print_summary
}

# ---------------------------------------------------------------------------
# 호스트: 이미지 준비 및 컨테이너 실행
# ---------------------------------------------------------------------------
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# 이미지 태그는 docker/ 디렉터리 내용의 해시다. Dockerfile 이나 tflint.hcl 이 바뀌면 태그가 바뀌어 자동 재빌드된다.
image_name() {
  local hash
  hash="$(cd "$SCRIPT_DIR/docker" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s\n' "$f"; cat "$f"; done | sha256_stdin)"
  printf '%s:%s\n' "$IMAGE_REPO" "${hash:0:12}"
}

ensure_image() {
  local image="$1"

  if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker 데몬에 연결할 수 없습니다. Docker Desktop(또는 docker 서비스)이 실행 중인지 확인하세요." >&2
    exit 2
  fi

  if [[ "$REBUILD" == false ]] && docker image inspect "$image" >/dev/null 2>&1; then
    return
  fi

  echo "==> 검증 이미지 빌드: $image (최초 1회 또는 docker/ 변경 시)" >&2
  docker build --label "solid-connection.verify=true" -t "$image" "$SCRIPT_DIR/docker" >&2

  # 이전 해시의 이미지는 정리한다. (실패해도 검증에는 영향 없음)
  docker image ls "$IMAGE_REPO" --format '{{.Repository}}:{{.Tag}}' \
    | { grep -vxF "$image" || true; } \
    | while read -r old; do docker image rm "$old" >/dev/null 2>&1 || true; done
}

# origin/main 대비 변경 파일로 L2 대상 환경을 고른다. (CI terraform-plan.yml 의 paths-filter 와 같은 기준)
# 기준 ref 와 비교할 수 없으면(미fetch, merge base 없음 등) 1 을 반환한다. 커밋된 변경이 감지에서 빠진 채
# "대상 없음"으로 통과하지 않도록, 호출부가 이를 L2 SKIPPED 로 기록한다.
detect_changed_envs() {
  local base="$1" committed files
  if ! committed="$(git -C "$REPO_ROOT" diff --name-only "$base"...HEAD 2>/dev/null)"; then
    return 1
  fi
  files="$committed
$(git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null)
$(git -C "$REPO_ROOT" ls-files --others --exclude-standard 2>/dev/null)"

  matches() { grep -qE "$1" <<<"$files"; }
  matches '^bootstrap/' && echo bootstrap
  matches '^(environment/global/|modules/shared_resources/|config/secrets$)' && echo global
  matches '^(environment/prod/|modules/app_stack/|modules/common/|config/side-infra/|config/secrets$)' && echo prod
  matches '^(environment/stage/|modules/app_stack/|modules/common/|config/side-infra/|config/secrets$)' && echo stage
  matches '^(environment/monitoring/|modules/monitoring_stack/|modules/common/|config/secrets$)' && echo monitoring
  matches '^(environment/load_test/|modules/app_stack/templates/|config/secrets$)' && echo load_test
  return 0
}

run_on_host() {
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  local image
  image="$(image_name)"

  if [[ "$PRINT_IMAGE" == true ]]; then
    echo "$image"
    return
  fi

  ensure_image "$image"

  local -a docker_args=(run --rm -i)
  [[ -t 0 && -t 1 ]] && docker_args+=(-t)

  # Git Bash(Windows)는 경로를 자동 변환하므로 막고, Docker 가 이해하는 Windows 경로를 넘긴다.
  local mount_root="$REPO_ROOT"
  if pwd -W >/dev/null 2>&1; then
    export MSYS_NO_PATHCONV=1
    mount_root="$(cd "$REPO_ROOT" && pwd -W)"
  fi

  docker_args+=(
    -v "$mount_root:/workspace:ro"
    -v "solid-connection-verify-cache:/cache"
    -e "VERIFY_LAYERS=${LAYERS[*]}"
    -e "VERIFY_STRICT=$STRICT"
  )

  # 의도 파일은 gitignore 대상(.verify/)에 둘 수 있으므로 레포 복사본이 아니라 별도로 마운트한다.
  if [[ -n "$EXPECT" ]]; then
    local expect_path="$EXPECT"
    [[ "$expect_path" == /* ]] || expect_path="$PWD/$expect_path"
    if [[ ! -f "$expect_path" ]]; then
      echo "ERROR: 의도 파일이 없습니다: $EXPECT" >&2
      exit 2
    fi
    local expect_dir
    expect_dir="$(cd "$(dirname "$expect_path")" && { pwd -W 2>/dev/null || pwd; })"
    docker_args+=(-v "$expect_dir/$(basename "$expect_path"):/tmp/verify-expect.txt:ro" -e "VERIFY_EXPECT=/tmp/verify-expect.txt")
  fi

  if [[ " ${LAYERS[*]} " == *" l2 "* ]]; then
    # macOS 기본 bash(3.2)는 set -u 에서 빈 배열 전개를 에러로 처리하므로 문자열로 다룬다.
    local env_list="$ENVS" detected detect_error="" auto=false
    if [[ -z "$env_list" ]]; then
      auto=true
      if detected="$(detect_changed_envs "$BASE_REF")"; then
        env_list="$(tr '\n' ' ' <<<"$detected")"
        echo "==> L2 대상 환경 (자동 감지, 기준 $BASE_REF): ${env_list:-(없음)}" >&2
      else
        detect_error="기준 ref '$BASE_REF' 와 비교할 수 없어 변경 환경을 감지하지 못함 (git fetch origin 후 재실행하거나 --base / --env 지정)"
        echo "WARN: $detect_error" >&2
      fi
    fi
    docker_args+=(-e "VERIFY_L2_ENVS=$env_list" -e "VERIFY_L2_DETECT_ERROR=$detect_error" -e "VERIFY_L2_AUTO=$auto")

    # plan 전문은 .verify/l2/ 에 남긴다. (gitignore 대상, 레포 마운트는 읽기 전용)
    mkdir -p "$REPO_ROOT/.verify"
    local out_dir="$REPO_ROOT/.verify"
    pwd -W >/dev/null 2>&1 && out_dir="$(cd "$out_dir" && pwd -W)"
    docker_args+=(-v "$out_dir:/out" -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)")

    # AWS 자격증명: ~/.aws 를 읽기 전용으로 넘기고, 환경 변수 방식도 그대로 전달한다.
    if [[ -d "$HOME/.aws" ]]; then
      local aws_dir="$HOME/.aws"
      pwd -W >/dev/null 2>&1 && aws_dir="$(cd "$HOME/.aws" && pwd -W)"
      docker_args+=(-v "$aws_dir:/root/.aws:ro")
    fi
    local var
    for var in AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
      [[ -n "${!var:-}" ]] && docker_args+=(-e "$var")
    done
  fi

  docker "${docker_args[@]}" "$image" bash /workspace/scripts/verify/verify.sh
}

# ---------------------------------------------------------------------------
# 인자 처리
# ---------------------------------------------------------------------------
main() {
  if [[ "${VERIFY_IN_CONTAINER:-}" == 1 ]]; then
    read -r -a LAYERS <<<"${VERIFY_LAYERS:-${DEFAULT_LAYERS[*]}}"
    run_in_container
    return
  fi

  LAYERS=() ENVS="" EXPECT="" BASE_REF="origin/main" STRICT=false REBUILD=false PRINT_IMAGE=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      l1|l2|l3) LAYERS+=("$1"); shift ;;
      all) LAYERS+=(l1 l2 l3); shift ;;
      --env)
        [[ " ${ALL_ENVS[*]} " == *" ${2:-} "* ]] || { echo "ERROR: 알 수 없는 환경: ${2:-}" >&2; exit 2; }
        ENVS="$ENVS $2"; shift 2 ;;
      --expect) EXPECT="$2"; shift 2 ;;
      --base) BASE_REF="$2"; shift 2 ;;
      --strict) STRICT=true; shift ;;
      --rebuild) REBUILD=true; shift ;;
      --print-image) PRINT_IMAGE=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "ERROR: 알 수 없는 인자: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
  [[ ${#LAYERS[@]} -eq 0 ]] && LAYERS=("${DEFAULT_LAYERS[@]}")

  # 계층 순서는 항상 L1 → L2 → L3, 중복 제거
  local -a ordered=()
  local l
  for l in l1 l2 l3; do
    [[ " ${LAYERS[*]} " == *" $l "* ]] && ordered+=("$l")
  done
  LAYERS=("${ordered[@]}")

  run_on_host
}

main "$@"
