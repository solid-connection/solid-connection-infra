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
    content = <<EOF
write_files:
  - path: /home/ubuntu/setup_nginx.sh
    owner: ubuntu:ubuntu
    permissions: '0755'
    content: |
${indent(6, templatefile("${path.module}/scripts/nginx_setup.sh.tftpl", {
      domain_name    = var.domain_name
      email          = var.cert_email
      conf_file_name = var.nginx_conf_name
    }))}
EOF
  }
}

resource "aws_instance" "monitoring_server" {
  ami           = var.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name

  associate_public_ip_address = true

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
