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

data "aws_instance" "prod_db" {
  filter {
    name   = "tag:Name"
    values = [var.prod_db_instance_name]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

data "aws_subnet" "stage_api" {
  id = data.aws_instance.stage_api.subnet_id
}

locals {
  load_test_db_subnet_id = var.load_test_db_subnet_id != null ? var.load_test_db_subnet_id : data.aws_instance.stage_api.subnet_id
  load_test_db_ami_id    = var.load_test_db_ami_id != null ? var.load_test_db_ami_id : data.aws_instance.prod_db.ami

  source_security_group_ids = setunion(
    data.aws_instance.prod_api.vpc_security_group_ids,
    data.aws_instance.stage_api.vpc_security_group_ids
  )
}

data "aws_subnet" "load_test_db" {
  id = local.load_test_db_subnet_id
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

resource "aws_security_group" "load_test_db" {
  name        = "sc-load-test-db-sg"
  description = "Security group for load test MySQL EC2"
  vpc_id      = data.aws_subnet.load_test_db.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "solid-connection-load-test-db-sg"
    Project = "solid-connection"
    Env     = "load_test"
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

resource "aws_ebs_volume" "load_test_db_data" {
  availability_zone = data.aws_subnet.load_test_db.availability_zone
  size              = var.allocated_storage
  type              = "gp3"
  encrypted         = true

  tags = {
    Name    = "${var.load_test_db_instance_name}-data"
    Project = "solid-connection"
    Env     = "load_test"
  }
}

resource "aws_instance" "load_test_db" {
  ami                         = local.load_test_db_ami_id
  instance_type               = var.load_test_db_instance_type
  subnet_id                   = local.load_test_db_subnet_id
  vpc_security_group_ids      = [aws_security_group.load_test_db.id]
  associate_public_ip_address = var.load_test_db_associate_public_ip
  iam_instance_profile        = var.load_test_db_instance_profile_name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/load_test_mysql_setup.sh.tftpl", {
    aws_region                 = "ap-northeast-2"
    data_volume_id             = aws_ebs_volume.load_test_db_data.id
    db_name                    = var.db_name
    load_test_parameter_prefix = var.load_test_parameter_prefix
    mysql_backup_bucket_name   = var.mysql_backup_bucket_name
    mysql_config_content       = file("${path.module}/../../modules/app_stack/templates/mysql_tuning.cnf")
  })

  user_data_replace_on_change = true

  tags = {
    Name    = var.load_test_db_instance_name
    Project = "solid-connection"
    Env     = "load_test"
  }
}

resource "aws_volume_attachment" "load_test_db_data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.load_test_db_data.id
  instance_id                    = aws_instance.load_test_db.id
  stop_instance_before_detaching = true
}

resource "aws_security_group" "load_generator" {
  count = var.create_load_generator ? 1 : 0

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
  count = var.create_load_generator ? 1 : 0

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.load_generator_instance_type
  subnet_id                   = data.aws_instance.stage_api.subnet_id
  vpc_security_group_ids      = [aws_security_group.load_generator[0].id]
  associate_public_ip_address = true
  iam_instance_profile        = var.load_generator_instance_profile_name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = var.load_generator_root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
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

resource "aws_ssm_parameter" "load_test_datasource_url" {
  name      = "${var.load_test_parameter_prefix}/spring.datasource.url"
  type      = "String"
  value     = "jdbc:mysql://${aws_instance.load_test_db.private_ip}:3306/${var.db_name}?serverTimezone=Asia/Seoul&characterEncoding=UTF-8"
  overwrite = true
}
