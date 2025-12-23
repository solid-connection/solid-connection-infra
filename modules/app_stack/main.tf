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

# 3. CloudInit을 이용한 User Data 스크립트 구성
data "cloudinit_config" "app_init" {
  gzip          = true
  base64_encode = true

  # [Part 1] Docker 설치 스크립트
  part {
    content_type = "text/x-shellscript"
    content      = file("${path.module}/scripts/docker_setup.sh")
    filename     = "1_docker_install.sh"
  }

  # [Part 2] Nginx 설정 스크립트
  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/scripts/nginx_setup.sh.tftpl", {
      domain_name = var.domain_name
      email       = var.cert_email
      conf_file_name = var.nginx_conf_name
    })
    filename = "2_nginx_setup.sh"
  }
}

# 4. API Server (EC2)
resource "aws_instance" "api_server" {
  ami           = var.ami_id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.api_sg.id]

  key_name = var.key_name
  associate_public_ip_address = true

  user_data_base64 = data.cloudinit_config.app_init.rendered
  
  tags = {
    Name = "solid-connection-server-${var.env_name}"
  }

  user_data_replace_on_change = false

  lifecycle {
    ignore_changes = [
      user_data,
      user_data_base64,
      user_data_replace_on_change,
      
      ami,
      key_name
    ]
  }
}

# 5. RDS
resource "aws_db_instance" "default" {
  identifier           = var.rds_identifier
  allocated_storage    = 20
  engine               = "mysql"
  engine_version       = var.db_engine_version
  instance_class       = var.db_instance_class
  username             = var.db_username
  password             = var.db_password
  parameter_group_name = var.db_parameter_group_name
  copy_tags_to_snapshot = true
  skip_final_snapshot  = true
  vpc_security_group_ids = [aws_security_group.db_sg.id]

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  tags = {
    Name = var.rds_identifier
  }
}

# 6. MySQL 추가 유저 생성
resource "mysql_user" "users" {
  for_each = var.additional_db_users

  user               = each.key
  host               = "%"
  plaintext_password = each.value.password

  depends_on = [aws_db_instance.default]
}

# 7. MySQL 권한 부여
resource "mysql_grant" "user_grants" {
  for_each = var.additional_db_users

  user       = each.key
  host       = "%"
  database   = each.value.database 
  privileges = each.value.privileges

  depends_on = [mysql_user.users]
}
