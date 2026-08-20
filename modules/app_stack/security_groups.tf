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

  # DB EC2 는 인터넷 경로가 없어 API EC2 의 app 포트로 백업 실패 알림을 보냅니다.
  # Blue/Green 활성 슬롯을 알 수 없어 두 슬롯의 포트를 모두 열고, 소스는 DB EC2 서브넷으로 제한합니다.
  # db_ec2_sg 가 이미 api_sg 를 참조하므로 보안 그룹을 소스로 쓰면 순환 참조가 되어 서브넷 CIDR 을 사용합니다.
  dynamic "ingress" {
    for_each = var.enable_db_ec2 ? toset(var.internal_alarm_api_ports) : toset([])
    content {
      description = "Internal backup alarm from DB EC2 subnet"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = [data.aws_subnet.db_ec2[0].cidr_block]
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

# 2. DB EC2용 보안 그룹 (API Server만 믿음)
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
