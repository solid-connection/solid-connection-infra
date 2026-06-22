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

locals {
  mysql_tuning_config_b64 = base64encode(file("${path.module}/templates/mysql_tuning.cnf"))

  mysql_tuning_ssm_params = jsonencode({
    commands = [
      "cloud-init status --wait > /dev/null",
      "sudo mkdir -p /etc/mysql/conf.d",
      "echo ${local.mysql_tuning_config_b64} | base64 -d | sudo tee /etc/mysql/conf.d/tuning.cnf > /dev/null",
      "sudo chmod 644 /etc/mysql/conf.d/tuning.cnf",
      "sudo docker restart mysql-server",
      "for i in $(seq 1 30); do if sudo docker exec mysql-server mysqladmin ping --silent >/dev/null 2>&1; then exit 0; fi; sleep 2; done; sudo docker logs --tail 100 mysql-server >&2; exit 1",
    ]
    executionTimeout = ["600"]
  })
}

resource "aws_instance" "db_server" {
  count = var.enable_db_ec2 ? 1 : 0

  ami           = var.db_ami_id
  instance_type = var.db_instance_type

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

resource "null_resource" "update_mysql_tuning" {
  count      = var.enable_db_ec2 ? 1 : 0
  depends_on = [aws_instance.db_server]

  triggers = {
    config_hash = sha256(file("${path.module}/templates/mysql_tuning.cnf"))
    instance_id = aws_instance.db_server[count.index].id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      INSTANCE_ID='${aws_instance.db_server[count.index].id}'
      COMMAND_ID=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters '${local.mysql_tuning_ssm_params}' \
        --output text \
        --query "Command.CommandId")
      ATTEMPTS=0
      while [ "$ATTEMPTS" -lt 60 ]; do
        STATUS=$(aws ssm get-command-invocation \
          --command-id "$COMMAND_ID" \
          --instance-id "$INSTANCE_ID" \
          --query "Status" --output text 2>/dev/null || echo "Pending")
        case "$STATUS" in
          Success) exit 0 ;;
          Failed|Cancelled|TimedOut|Undeliverable)
            echo "SSM command $STATUS" >&2
            aws ssm get-command-invocation \
              --command-id "$COMMAND_ID" \
              --instance-id "$INSTANCE_ID" \
              --query "StandardErrorContent" --output text >&2
            exit 1 ;;
        esac
        ATTEMPTS=$((ATTEMPTS + 1))
        sleep 10
      done
      echo "SSM command timed out after 600s" >&2
      exit 1
    EOT
  }
}
