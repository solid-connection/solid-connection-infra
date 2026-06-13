data "aws_instance" "monitoring_server" {
  filter {
    name   = "tag:Name"
    values = ["solid-connection-monitoring"]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

# CloudInit을 이용한 User Data 스크립트 구성
data "cloudinit_config" "app_init" {
  gzip          = true
  base64_encode = true

  # [Part 1] Docker 설치 스크립트
  part {
    content_type = "text/x-shellscript"
    content      = file("${path.module}/../common/scripts/docker_setup.sh")
    filename     = "1_docker_install.sh"
  }

}

# API Server (EC2)
resource "aws_instance" "api_server" {
  ami           = var.ami_id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.api_sg.id]

  key_name                    = var.key_name
  associate_public_ip_address = true
  iam_instance_profile        = var.ec2_iam_instance_profile

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

locals {
  nginx_script_b64 = base64encode(templatefile("${path.module}/scripts/nginx_setup.sh.tftpl", {
    domain_name    = var.domain_name
    email          = var.cert_email
    conf_file_name = var.nginx_conf_name
  }))

  alloy_config = templatefile("${path.module}/../../config/side-infra/config.alloy.tftpl", {
    loki_ip = data.aws_instance.monitoring_server.private_ip
  })

  side_infra_script_b64 = base64encode(templatefile("${path.module}/scripts/side_infra_setup.sh.tftpl", {
    work_dir               = var.work_dir
    alloy_env_name         = var.alloy_env_name
    alloy_config_content   = local.alloy_config
    redis_version          = var.redis_version
    redis_exporter_version = var.redis_exporter_version
    alloy_version          = var.alloy_version
  }))

  nginx_ssm_params = jsonencode({
    commands         = ["cloud-init status --wait > /dev/null", "echo ${local.nginx_script_b64} | base64 -d | sudo bash"]
    executionTimeout = ["3600"]
  })

  side_infra_ssm_params = jsonencode({
    commands         = ["cloud-init status --wait > /dev/null", "echo ${local.side_infra_script_b64} | base64 -d | sudo bash"]
    executionTimeout = ["3600"]
  })
}

# [리소스 1] Nginx 설정 변경 감지 및 실행
resource "null_resource" "update_nginx" {
  depends_on = [aws_instance.api_server]

  triggers = {
    script_hash = sha256(templatefile("${path.module}/scripts/nginx_setup.sh.tftpl", {
      domain_name    = var.domain_name
      email          = var.cert_email
      conf_file_name = var.nginx_conf_name
    }))
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      INSTANCE_ID='${aws_instance.api_server.id}'
      COMMAND_ID=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters '${local.nginx_ssm_params}' \
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

# [리소스 2] Side Infra 설정 변경 감지 및 실행
resource "null_resource" "update_side_infra" {
  depends_on = [aws_instance.api_server]

  triggers = {
    script_hash = sha256(templatefile("${path.module}/scripts/side_infra_setup.sh.tftpl", {
      work_dir       = var.work_dir
      alloy_env_name = var.alloy_env_name
      alloy_config_content = templatefile("${path.module}/../../config/side-infra/config.alloy.tftpl", {
        loki_ip = data.aws_instance.monitoring_server.private_ip
      })
      redis_version          = var.redis_version
      redis_exporter_version = var.redis_exporter_version
      alloy_version          = var.alloy_version
    }))
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      INSTANCE_ID='${aws_instance.api_server.id}'
      COMMAND_ID=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters '${local.side_infra_ssm_params}' \
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
