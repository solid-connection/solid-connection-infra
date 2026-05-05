#!/bin/bash

set -euo pipefail

# 에러 발생 시 메시지 출력
trap 'echo "❌ 오류 발생! 스크립트 실행이 중단되었습니다." >&2' ERR

export GO_VERSION=1.22.2
export BASE_DIR=/home/ubuntu/solid-connection-load-test/k6
export GOROOT=${BASE_DIR}/go
export GOPATH=${BASE_DIR}/go-workspace
export PATH=$PATH:$GOROOT/bin:$GOPATH/bin
export XK6_BIN=${GOPATH}/bin/xk6
export K6_OUT=xk6-prometheus-rw
export K6_PROMETHEUS_RW_SERVER_URL=http://132.145.83.182:9090/api/v1/write
export K6_PROMETHEUS_RW_TREND_STATS="p(90),p(95),p(99),avg,min,max"
{
  echo "export BASE_DIR=${BASE_DIR}"
  echo "export GOROOT=${GOROOT}"
  echo "export GOPATH=${GOPATH}"
  echo "export PATH=\$PATH:\$GOROOT/bin:\$GOPATH/bin"
  echo "export XK6_BIN=${GOPATH}/bin/xk6"
  echo "export K6_OUT=xk6-prometheus-rw"
  echo "export K6_PROMETHEUS_RW_SERVER_URL=http://146.56.46.8:9090/api/v1/write"
  echo "K6_PROMETHEUS_RW_TREND_STATS=\"p(90),p(95),p(99),avg,min,max\""
} >> ~/.bashrc

echo "📁 디렉토리 생성 및 이동: $BASE_DIR"
mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

echo "⬇️ Go $GO_VERSION 다운로드 중..."
curl -OL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"

echo "📦 Go 압축 해제 중..."
tar -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
rm "go${GO_VERSION}.linux-amd64.tar.gz"

echo "✅ Go 버전 확인: $(go version)"

echo "⬇️ xk6 설치 중..."
go install go.k6.io/xk6/cmd/xk6@latest

echo "✅ xk6 설치 완료: $XK6_BIN"
$XK6_BIN --help > /dev/null && echo "✅ xk6 실행 가능"

echo "⚙️ Prometheus remote-write 플러그인을 포함한 K6 빌드 시작"
$XK6_BIN build --with github.com/grafana/xk6-output-prometheus-remote@latest

echo "✅ 빌드 완료: $(pwd)/k6"
ls -lh ./k6

echo "🎉 설치가 성공적으로 완료되었습니다!"
