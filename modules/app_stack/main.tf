terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3" 
    }
    mysql = {
      source  = "petoju/mysql"
      version = ">= 3.0"
    }
  }
}

provider "mysql" {
  endpoint = "127.0.0.1:3306"
  username = var.db_username
  password = var.db_password
}

# 1. API Server용 보안 그룹 (SSH 연결 허용)
resource "aws_security_group" "api_sg" {
  name        = "sc-${var.env_name}-api-sg"
  description = "Security Group for API Server"
  vpc_id      = var.vpc_id

  tags = {
    Name = "solid-connection-server-${var.env_name}-sg"
  }
}

# 2. RDS용 보안 그룹 (API Server만 믿음)
resource "aws_security_group" "db_sg" {
  name        = "sc-${var.env_name}-db-sg"
  description = "Security Group for RDS"
  vpc_id      = var.vpc_id

  tags = {
    Name = "solid-connection-${var.env_name}-db-sg"
  }
}

# 3. CloudInit을 이용한 User Data 스크립트 구성
data "cloudinit_config" "app_init" {
  gzip          = true  # 압축하여 UserData 용량 제한(64KB) 극복
  base64_encode = true  # EC2 UserData는 Base64 필수

  # [Part 1] Docker 설치 스크립트
  part {
    content_type = "text/x-shellscript"
    content      = file("${path.module}/scripts/docker_setup.sh")
    filename     = "1_docker_install.sh"
  }

  # [Part 2] Nginx 설정 스크립트
  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/scripts/nginx_setup.tftpl", {
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

  # User Data가 변경되면 인스턴스를 새로 만들 것인지 결정, true로 설정하면 스크립트 수정 시 기존 서버를 삭제하고 새 서버를 띄웁니다.
  user_data_base64 = data.cloudinit_config.app_init.rendered
  
  tags = {
    Name = "solid-connection-server-${var.env_name}"
  }

  user_data_replace_on_change = false # true면 User Data 변경 시 인스턴스 교체

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