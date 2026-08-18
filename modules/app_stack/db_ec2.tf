data "aws_subnet" "db_ec2" {
  count = var.enable_db_ec2 ? 1 : 0

  id = var.db_subnet_id
}

resource "aws_ebs_volume" "db_data" {
  count = var.enable_db_ec2 ? 1 : 0

  availability_zone = data.aws_subnet.db_ec2[count.index].availability_zone
  size              = var.db_data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "solid-connection-db-mysql-data-${var.env_name}"
  }

  lifecycle {
    prevent_destroy = true
  }
}

data "cloudinit_config" "db_init" {
  count         = var.enable_db_ec2 ? 1 : 0
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/scripts/mysql_setup.sh.tftpl", {
      db_root_username_b64 = base64encode(var.db_username)
      db_root_password_b64 = base64encode(var.db_password)
      db_data_volume_id    = aws_ebs_volume.db_data[count.index].id
      mysql_config_content = file("${path.module}/templates/mysql_tuning.cnf")
    })
    filename = "mysql_setup.sh"
  }
}

resource "aws_instance" "db_server" {
  count = var.enable_db_ec2 ? 1 : 0

  ami           = var.db_ami_id
  instance_type = var.db_instance_type
  subnet_id     = var.db_subnet_id

  vpc_security_group_ids      = [aws_security_group.db_ec2_sg[count.index].id]
  associate_public_ip_address = false
  iam_instance_profile        = var.ec2_iam_instance_profile
  key_name                    = var.key_name

  user_data_base64 = data.cloudinit_config.db_init[count.index].rendered

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

  tags = {
    Name = "solid-connection-db-mysql-${var.env_name}"
  }

  user_data_replace_on_change = false

  lifecycle {
    # AMI 갱신이 운영 중인 DB EC2를 교체하지 않도록 무시하고, 인스턴스가 재생성되는 시점에 새 AMI를 적용합니다.
    ignore_changes = [
      ami,
      key_name,
      user_data,
      user_data_base64,
      user_data_replace_on_change,
    ]
  }
}

resource "aws_volume_attachment" "db_data" {
  count = var.enable_db_ec2 ? 1 : 0

  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.db_data[count.index].id
  instance_id                    = aws_instance.db_server[count.index].id
  stop_instance_before_detaching = true
}
