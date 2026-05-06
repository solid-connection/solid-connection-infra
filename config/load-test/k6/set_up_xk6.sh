#!/bin/bash

set -euo pipefail

trap 'echo "xk6 setup failed" >&2' ERR

export GO_VERSION=1.22.2
export BASE_DIR=/home/ubuntu/solid-connection-load-test/k6
export GOROOT=${BASE_DIR}/go
export GOPATH=${BASE_DIR}/go-workspace
export PATH=$PATH:$GOROOT/bin:$GOPATH/bin
export XK6_BIN=${GOPATH}/bin/xk6
export K6_OUT=xk6-prometheus-rw
export K6_PROMETHEUS_RW_SERVER_URL=${K6_PROMETHEUS_RW_SERVER_URL:-http://132.145.83.182:9090/api/v1/write}
export K6_PROMETHEUS_RW_TREND_STATS="${K6_PROMETHEUS_RW_TREND_STATS:-p(90),p(95),p(99),avg,min,max}"

{
  echo "export BASE_DIR=${BASE_DIR}"
  echo "export GOROOT=${GOROOT}"
  echo "export GOPATH=${GOPATH}"
  echo "export PATH=\$PATH:\$GOROOT/bin:\$GOPATH/bin"
  echo "export XK6_BIN=${GOPATH}/bin/xk6"
  echo "export K6_OUT=xk6-prometheus-rw"
  echo "export K6_PROMETHEUS_RW_SERVER_URL=${K6_PROMETHEUS_RW_SERVER_URL}"
  echo "export K6_PROMETHEUS_RW_TREND_STATS=\"${K6_PROMETHEUS_RW_TREND_STATS}\""
} >> ~/.bashrc

echo "Create and enter ${BASE_DIR}"
mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

echo "Download Go ${GO_VERSION}"
curl -OL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"

echo "Extract Go"
tar -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
rm "go${GO_VERSION}.linux-amd64.tar.gz"

echo "Go version: $(go version)"

echo "Install xk6"
go install go.k6.io/xk6/cmd/xk6@latest

echo "xk6 installed: ${XK6_BIN}"
"$XK6_BIN" --help > /dev/null && echo "xk6 executable is available"

echo "Build k6 with Prometheus remote-write output"
"$XK6_BIN" build --with github.com/grafana/xk6-output-prometheus-remote@latest

echo "Build complete: $(pwd)/k6"
ls -lh ./k6

echo "xk6 setup completed"
