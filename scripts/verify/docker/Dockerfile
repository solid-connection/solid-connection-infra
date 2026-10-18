# syntax=docker/dockerfile:1
#
# solid-connection-infra 검증 이미지 (L1 정적 검사 / L2 plan 검사 / L3 동작 테스트)
#
# 작업자의 OS(macOS/Windows/Linux)와 무관하게 같은 도구, 같은 버전으로 검증하기 위한 이미지다.
# 이 디렉터리의 파일이 바뀌면 scripts/verify/verify.sh 가 이미지 태그(파일 해시)가 바뀐 것을 감지해 자동으로 다시 빌드한다.
# 도구 버전을 올릴 때는 아래 ARG 만 수정한다. (tflint AWS ruleset 버전은 tflint.hcl 에서 관리)

FROM python:3.12-slim-bookworm@sha256:34386ef0cb081344d7ec1c103ba398e6e9f64e9ab3a1509accc92a4e24a07258

# CI(.github/workflows/terraform-plan.yml)의 TF_VERSION 과 맞춘다.
ARG TERRAFORM_VERSION=1.10.5
ARG TFLINT_VERSION=0.64.0
ARG TRIVY_VERSION=0.75.0
ARG ACTIONLINT_VERSION=1.7.12
ARG SHELLCHECK_VERSION=0.11.0
ARG TARGETARCH

SHELL ["/bin/bash", "-Eeuo", "pipefail", "-c"]

RUN apt-get update \
  && apt-get install -y --no-install-recommends bash ca-certificates curl unzip xz-utils jq netcat-openbsd procps \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/install

# 체크섬 파일에서 해당 아티팩트 줄을 찾아 검증한다.
# $1: 체크섬 파일, $2: 아티팩트 파일명
RUN cat >/usr/local/bin/verify-checksum <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
grep -E "[[:space:]]\*?$2\$" "$1" | sha256sum -c -
EOF
RUN chmod +x /usr/local/bin/verify-checksum

RUN case "$TARGETARCH" in amd64|arm64) ;; *) echo "지원하지 않는 아키텍처: $TARGETARCH" >&2; exit 1 ;; esac

# Terraform
RUN base="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}" \
  && file="terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" \
  && curl -fsSLO "$base/$file" \
  && curl -fsSLO "$base/terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
  && verify-checksum "terraform_${TERRAFORM_VERSION}_SHA256SUMS" "$file" \
  && unzip -q "$file" -d /usr/local/bin \
  && rm -rf /tmp/install/*

# TFLint
RUN base="https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}" \
  && file="tflint_linux_${TARGETARCH}.zip" \
  && curl -fsSLO "$base/$file" \
  && curl -fsSLO "$base/checksums.txt" \
  && verify-checksum checksums.txt "$file" \
  && unzip -q "$file" -d /usr/local/bin \
  && rm -rf /tmp/install/*

# Trivy (IaC 보안 스캔)
RUN base="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}" \
  && arch="$([[ "$TARGETARCH" == amd64 ]] && echo 64bit || echo ARM64)" \
  && file="trivy_${TRIVY_VERSION}_Linux-${arch}.tar.gz" \
  && curl -fsSLO "$base/$file" \
  && curl -fsSLO "$base/trivy_${TRIVY_VERSION}_checksums.txt" \
  && verify-checksum "trivy_${TRIVY_VERSION}_checksums.txt" "$file" \
  && tar -xzf "$file" -C /usr/local/bin trivy \
  && rm -rf /tmp/install/*

# actionlint (GitHub Actions 워크플로우 lint)
RUN base="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}" \
  && file="actionlint_${ACTIONLINT_VERSION}_linux_${TARGETARCH}.tar.gz" \
  && curl -fsSLO "$base/$file" \
  && curl -fsSLO "$base/actionlint_${ACTIONLINT_VERSION}_checksums.txt" \
  && verify-checksum "actionlint_${ACTIONLINT_VERSION}_checksums.txt" "$file" \
  && tar -xzf "$file" -C /usr/local/bin actionlint \
  && rm -rf /tmp/install/*

# ShellCheck (공식 릴리스에 체크섬 파일이 없어 버전 고정으로만 관리)
RUN arch="$([[ "$TARGETARCH" == amd64 ]] && echo x86_64 || echo aarch64)" \
  && curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.${arch}.tar.xz" \
    | tar -xJf - --strip-components=1 -C /usr/local/bin "shellcheck-v${SHELLCHECK_VERSION}/shellcheck"

# AWS CLI v2 + Session Manager Plugin (L2 plan 의 자격증명 확인 및 prod DB SSM 터널용)
RUN arch="$([[ "$TARGETARCH" == amd64 ]] && echo x86_64 || echo aarch64)" \
  && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o awscliv2.zip \
  && unzip -q awscliv2.zip \
  && ./aws/install \
  && ssm_arch="$([[ "$TARGETARCH" == amd64 ]] && echo ubuntu_64bit || echo ubuntu_arm64)" \
  && curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/${ssm_arch}/session-manager-plugin.deb" -o ssm.deb \
  && dpkg -i ssm.deb \
  && rm -rf /tmp/install/*

# TFLint 플러그인은 이미지에 미리 받아 둔다. (실행 시 GitHub API 호출/rate limit 회피)
ENV TFLINT_PLUGIN_DIR=/opt/tflint/plugins
COPY tflint.hcl /opt/tflint/tflint.hcl
RUN tflint --init --config /opt/tflint/tflint.hcl

RUN terraform version && tflint --version && trivy --version && actionlint --version \
  && shellcheck --version && aws --version && session-manager-plugin --version && python3 --version

# 레포가 .terraform.lock.hcl 을 커밋하지 않으므로, lock 파일 없이도 provider 캐시를 쓰도록 허용한다.
ENV TF_IN_AUTOMATION=1 \
    TF_INPUT=0 \
    TF_PLUGIN_CACHE_DIR=/cache/terraform-plugins \
    TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true \
    TRIVY_CACHE_DIR=/cache/trivy \
    VERIFY_IN_CONTAINER=1

WORKDIR /work
