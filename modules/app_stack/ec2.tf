# 3. CloudInit을 이용한 User Data 스크립트 구성
data "cloudinit_config" "app_init" {
  gzip          = true
  base64_encode = true

  # [Part 1] Docker 설치 스크립트
  part {
    content_type = "text/x-shellscript"
    content      = file("${path.module}/scripts/docker_setup.sh")
    filename     = "1_docker_install.sh"
  }

  # [Part 2] Nginx 설정 스크립트
  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/scripts/nginx_setup.sh.tftpl", {
      domain_name    = var.domain_name
      email          = var.cert_email
      conf_file_name = var.nginx_conf_name
    })
    filename = "2_nginx_setup.sh"
  }
}

# 4. API Server (EC2)
resource "aws_instance" "api_server" {
  ami           = var.ami_id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.api_sg.id]

  key_name                    = var.key_name
  associate_public_ip_address = true

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
