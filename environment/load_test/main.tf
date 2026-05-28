data "aws_instance" "prod_api" {
  filter {
    name   = "tag:Name"
    values = [var.prod_api_instance_name]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

data "aws_instance" "stage_api" {
  filter {
    name   = "tag:Name"
    values = [var.stage_api_instance_name]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

data "aws_subnet" "stage_api" {
  id = data.aws_instance.stage_api.subnet_id
}

data "aws_subnets" "target" {
  filter {
    name   = "vpc-id"
    values = [data.aws_subnet.stage_api.vpc_id]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_db_instance" "prod" {
  db_instance_identifier = var.prod_rds_identifier
}

data "aws_db_snapshot" "latest_prod" {
  db_instance_identifier = var.prod_rds_identifier
  most_recent            = true
  snapshot_type          = "automated"
}

data "aws_ssm_parameter" "prod_db_username" {
  name = var.prod_db_username_parameter_name
}

data "aws_ssm_parameter" "prod_db_password" {
  name            = var.prod_db_password_parameter_name
  with_decryption = true
}

locals {
  source_security_group_ids = setunion(
    data.aws_instance.prod_api.vpc_security_group_ids,
    data.aws_instance.stage_api.vpc_security_group_ids
  )
}

resource "aws_security_group" "load_test_db" {
  name        = "sc-load-test-db-sg"
  description = "Security group for load test RDS"
  vpc_id      = data.aws_subnet.stage_api.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "solid-connection-load-test-db-sg"
  }
}

resource "aws_security_group_rule" "load_test_db_mysql" {
  for_each = local.source_security_group_ids

  type                     = "ingress"
  description              = "MySQL from prod/stage API server"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.load_test_db.id
  source_security_group_id = each.value
}

resource "aws_security_group" "load_generator" {
  name        = "sc-load-test-generator-sg"
  description = "Security group for k6 load generator"
  vpc_id      = data.aws_subnet.stage_api.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "solid-connection-load-test-generator-sg"
  }
}

resource "aws_instance" "load_generator" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.load_generator_instance_type
  subnet_id                   = data.aws_instance.stage_api.subnet_id
  vpc_security_group_ids      = [aws_security_group.load_generator.id]
  associate_public_ip_address = true
  iam_instance_profile        = var.load_generator_instance_profile_name

  root_block_device {
    volume_size = var.load_generator_root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOF
    #!/bin/bash
    set -eux
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl jq
    snap install amazon-ssm-agent --classic || true
    systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service || true
    systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service || true
  EOF

  tags = {
    Name = "solid-connection-load-test-generator"
  }
}

resource "aws_db_subnet_group" "load_test" {
  name       = "sc-load-test-db-subnet-group"
  subnet_ids = data.aws_subnets.target.ids

  tags = {
    Name = "solid-connection-load-test-db-subnet-group"
  }
}

resource "aws_db_instance" "load_test" {
  identifier              = var.rds_identifier
  instance_class          = var.db_instance_class
  parameter_group_name    = var.db_parameter_group_name
  snapshot_identifier     = data.aws_db_snapshot.latest_prod.id
  db_subnet_group_name    = aws_db_subnet_group.load_test.name
  vpc_security_group_ids  = [aws_security_group.load_test_db.id]
  publicly_accessible     = false
  skip_final_snapshot     = true
  copy_tags_to_snapshot   = true
  deletion_protection     = false
  backup_retention_period = 0
  apply_immediately       = true
  storage_encrypted       = true
  kms_key_id              = var.kms_key_arn

  tags = {
    Name = var.rds_identifier
  }
}

resource "aws_ssm_parameter" "load_test_datasource_url" {
  name      = "${var.load_test_parameter_prefix}/spring.datasource.url"
  type      = "String"
  value     = "jdbc:mysql://${aws_db_instance.load_test.address}:${aws_db_instance.load_test.port}/${var.db_name}?serverTimezone=Asia/Seoul&characterEncoding=UTF-8"
  overwrite = true
}

resource "aws_ssm_parameter" "load_test_datasource_username" {
  name      = "${var.load_test_parameter_prefix}/spring.datasource.username"
  type      = "String"
  value     = data.aws_ssm_parameter.prod_db_username.value
  overwrite = true
}

resource "aws_ssm_parameter" "load_test_datasource_password" {
  name      = "${var.load_test_parameter_prefix}/spring.datasource.password"
  type      = "SecureString"
  value     = data.aws_ssm_parameter.prod_db_password.value
  key_id    = var.ssm_kms_key_id
  overwrite = true
  tier      = "Standard"
}
