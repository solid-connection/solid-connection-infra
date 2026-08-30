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

  # 인스턴스가 교체되면 새 인스턴스에는 nginx 가 없으므로 설정 스크립트를 다시 실행합니다.
  # triggers 대신 lifecycle 을 쓰는 이유: triggers 는 state 에 저장되어 키를 추가하는 것만으로 재실행이 발생합니다.
  # 리소스 전체가 아니라 id 를 참조하는 이유: 리소스 참조는 in-place update 에도 반응하지만,
  # 속성 참조는 값이 바뀔 때만 반응하므로 인스턴스 교체에만 발동합니다.
  lifecycle {
    replace_triggered_by = [aws_instance.api_server.id]
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      INSTANCE_ID='${aws_instance.api_server.id}'

      # 인스턴스가 교체된 직후에는 SSM 에이전트가 아직 등록되지 않아
      # send-command 가 InvalidInstanceId 로 즉시 실패합니다. 등록될 때까지 기다립니다.
      PING_STATUS=""
      SSM_ATTEMPTS=0
      while [ "$SSM_ATTEMPTS" -lt 60 ]; do
        PING_STATUS=$(aws ssm describe-instance-information \
          --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
          --query "InstanceInformationList[0].PingStatus" \
          --output text 2>/dev/null || echo "None")
        if [ "$PING_STATUS" = "Online" ]; then
          break
        fi
        SSM_ATTEMPTS=$((SSM_ATTEMPTS + 1))
        sleep 10
      done
      if [ "$PING_STATUS" != "Online" ]; then
        echo "SSM agent not registered within 600s (last status: $PING_STATUS)" >&2
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
