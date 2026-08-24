# 1. API Server용 보안 그룹 (SSH 연결 허용)
resource "aws_security_group" "api_sg" {
  name        = "sc-${var.env_name}-api-sg"
  description = "Security Group for API Server"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.api_ingress_rules
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
    }
  }

  # DB EC2 는 인터넷 경로가 없어 API EC2 를 거쳐 백업 실패 알림을 보냅니다.
  # Blue/Green 활성 슬롯을 알 수 없어 두 슬롯의 app 포트를 모두 열고,
  # 설치 검증에서 /actuator/health 를 확인하기 위해 management 포트도 함께 엽니다.
  # 소스는 DB EC2 에만 붙는 알림 전용 보안 그룹이므로 같은 서브넷의 다른 인스턴스는 접근할 수 없습니다.
  dynamic "ingress" {
    for_each = var.enable_db_ec2 ? toset(concat(
      var.internal_alarm_api_ports,
      var.internal_alarm_api_management_ports
    )) : toset([])
    content {
      description     = "Internal backup alarm from DB EC2"
      from_port       = ingress.value
      to_port         = ingress.value
      protocol        = "tcp"
      security_groups = [aws_security_group.db_ec2_alarm_client_sg[0].id]
    }
  }

  # [Outbound] 모든 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "solid-connection-server-${var.env_name}-sg"
  }
}

# 2. DB EC2 알림 클라이언트용 보안 그룹
# - DB EC2 가 API 서버의 알림 경로를 호출할 때 출처를 특정하기 위한 그룹입니다.
# - 인바운드 규칙이 없어 api_sg 를 참조하지 않으므로, db_ec2_sg 와 달리 순환 참조가 생기지 않습니다.
resource "aws_security_group" "db_ec2_alarm_client_sg" {
  count       = var.enable_db_ec2 ? 1 : 0
  name        = "sc-${var.env_name}-db-ec2-alarm-client-sg"
  description = "Client Security Group for DB EC2 backup alarm requests"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "solid-connection-db-ec2-alarm-client-${var.env_name}-sg"
  }
}

# 3. DB EC2용 보안 그룹 (API Server만 믿음)
resource "aws_security_group" "db_ec2_sg" {
  count       = var.enable_db_ec2 ? 1 : 0
  name        = "sc-${var.env_name}-db-ec2-sg"
  description = "Security Group for DB EC2"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.db_ec2_ingress_rules
    content {
      description     = ingress.value.description
      from_port       = ingress.value.from_port
      to_port         = ingress.value.to_port
      protocol        = ingress.value.protocol
      security_groups = [aws_security_group.api_sg.id]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "solid-connection-${var.env_name}-db-ec2-sg"
  }
}

# 3. RDS용 보안 그룹 (API Server만 믿음)
resource "aws_security_group" "db_sg" {
  count       = var.enable_rds ? 1 : 0
  name        = "sc-${var.env_name}-db-sg"
  description = "Security Group for RDS"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.rds_ingress_rules
    content {
      description     = ingress.value.description
      from_port       = ingress.value.from_port
      to_port         = ingress.value.to_port
      protocol        = ingress.value.protocol
      security_groups = [aws_security_group.api_sg.id]
    }
  }

  tags = {
    Name = "solid-connection-${var.env_name}-db-sg"
  }
}
