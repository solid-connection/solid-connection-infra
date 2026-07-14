locals {
  nginx_setup_script = templatefile("${path.module}/scripts/nginx_setup.sh.tftpl", {
    domain_name    = var.domain_name
    email          = var.cert_email
    conf_file_name = var.nginx_conf_name
  })

  nginx_script_b64 = base64encode(local.nginx_setup_script)

  nginx_ssm_params = jsonencode({
    commands         = ["cloud-init status --wait > /dev/null", "echo ${local.nginx_script_b64} | base64 -d | sudo bash"]
    executionTimeout = ["3600"]
  })
}

data "cloudinit_config" "app_init" {
  gzip          = true
  base64_encode = true

  # [Part 1] Docker 설치 스크립트
  part {
    content_type = "text/x-shellscript"
    content      = file("${path.module}/../common/scripts/docker_setup.sh")
    filename     = "1_docker_install.sh"
  }

  # [Part 2] Nginx 설정 스크립트 파일 생성 (실행 안 함, 파일만 생성)
  part {
    content_type = "text/cloud-config"
    content      = <<EOF
write_files:
  - path: /home/ubuntu/setup_nginx.sh
    owner: ubuntu:ubuntu
    permissions: '0755'
    content: |
${indent(6, local.nginx_setup_script)}
EOF
  }
}

resource "aws_instance" "monitoring_server" {
  ami           = var.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name

  associate_public_ip_address = true
  iam_instance_profile        = var.ec2_iam_instance_profile

  vpc_security_group_ids = [aws_security_group.monitoring_sg.id]

  user_data_base64 = data.cloudinit_config.app_init.rendered

  user_data_replace_on_change = false

  private_ip = var.private_ip

  tags = {
    Name = "solid-connection-monitoring"
  }

  lifecycle {
    ignore_changes = [
      user_data,
      user_data_base64,
      ami
    ]
  }
}

resource "terraform_data" "update_nginx" {
  count = var.ec2_iam_instance_profile == null ? 0 : 1

  depends_on = [aws_instance.monitoring_server]

  triggers_replace = {
    instance_id = aws_instance.monitoring_server.id
    script_hash = sha256(local.nginx_setup_script)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      INSTANCE_ID='${aws_instance.monitoring_server.id}'
      ATTEMPTS=0
      while [ "$ATTEMPTS" -lt 60 ]; do
        PING_STATUS=$(aws ssm describe-instance-information \
          --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
          --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null || echo "Offline")
        if [ "$PING_STATUS" = "Online" ]; then
          break
        fi
        ATTEMPTS=$((ATTEMPTS + 1))
        sleep 10
      done
      if [ "$PING_STATUS" != "Online" ]; then
        echo "SSM agent did not become online after 600s" >&2
        exit 1
      fi

      COMMAND_ID=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters '${local.nginx_ssm_params}' \
        --output text \
        --query "Command.CommandId")
      ATTEMPTS=0
      while [ "$ATTEMPTS" -lt 360 ]; do
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
      echo "SSM command timed out after 3600s" >&2
      exit 1
    EOT
  }
}
