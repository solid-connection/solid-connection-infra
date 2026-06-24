data "cloudinit_config" "db_init" {
  count         = var.enable_db_ec2 ? 1 : 0
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/scripts/mysql_setup.sh.tftpl", {
      db_root_username_b64 = base64encode(var.db_username)
      db_root_password_b64 = base64encode(var.db_password)
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
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "solid-connection-db-mysql-${var.env_name}"
  }

  user_data_replace_on_change = false

  lifecycle {
    ignore_changes = [
      user_data,
      user_data_base64,
      user_data_replace_on_change,
      key_name,
    ]
  }
}
