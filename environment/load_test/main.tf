data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

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

data "aws_db_instance" "prod" {
  db_instance_identifier = var.prod_rds_identifier
}

data "aws_ssm_parameter" "db_root_username" {
  name = var.load_test_db_username_parameter_name
}

data "aws_ssm_parameter" "db_root_password" {
  name            = var.load_test_db_password_parameter_name
  with_decryption = true
}

locals {
  db_root_username = data.aws_ssm_parameter.db_root_username.value
  db_root_password = data.aws_ssm_parameter.db_root_password.value

  source_security_group_ids = setunion(
    data.aws_instance.prod_api.vpc_security_group_ids,
    data.aws_instance.stage_api.vpc_security_group_ids
  )
}

resource "aws_security_group" "load_test_db" {
  name        = "sc-load-test-db-sg"
  description = "Security group for load test RDS"
  vpc_id      = data.aws_vpc.default.id

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

resource "aws_db_subnet_group" "load_test" {
  name       = "sc-load-test-db-subnet-group"
  subnet_ids = data.aws_subnets.default.ids

  tags = {
    Name = "solid-connection-load-test-db-subnet-group"
  }
}

resource "aws_db_instance" "load_test" {
  identifier              = var.rds_identifier
  allocated_storage       = var.allocated_storage
  engine                  = "mysql"
  engine_version          = var.db_engine_version
  instance_class          = var.db_instance_class
  db_name                 = var.db_name
  username                = local.db_root_username
  password                = local.db_root_password
  parameter_group_name    = var.db_parameter_group_name
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
  value     = local.db_root_username
  overwrite = true
}

resource "aws_ssm_parameter" "load_test_datasource_password" {
  name      = "${var.load_test_parameter_prefix}/spring.datasource.password"
  type      = "SecureString"
  value     = local.db_root_password
  key_id    = var.ssm_kms_key_id
  overwrite = true
  tier      = "Standard"
}
