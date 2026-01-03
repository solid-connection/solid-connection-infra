data "aws_instance" "monitoring_ec2" {
  filter {
    name   = "tag:Name"
    values = ["solid-connection-monitoring"]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

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

  ingress {
    description = "Allow 8081 from EC2: (${data.aws_instance.monitoring_ec2.tags.Name})"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"

    cidr_blocks = ["${data.aws_instance.monitoring_ec2.private_ip}/32"]
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

# 2. RDS용 보안 그룹 (API Server만 믿음)
resource "aws_security_group" "db_sg" {
  name        = "sc-${var.env_name}-db-sg"
  description = "Security Group for RDS"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.db_ingress_rules
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
