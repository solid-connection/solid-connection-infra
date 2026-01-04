#!/bin/bash

# 1. 필수 패키지 설치
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release

# 2. Docker 공식 GPG Key 추가
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# 3. Docker Repository 설정
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# 4. Docker Engine 설치
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 5. ubuntu 유저에게 Docker 권한 부여
usermod -aG docker ubuntu

# 6. 서비스 시작 및 활성화
systemctl enable docker
systemctl start docker
