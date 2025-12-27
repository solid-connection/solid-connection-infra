# CloudInit을 이용한 User Data 스크립트 구성
data "cloudinit_config" "app_init" {
  gzip          = true
  base64_encode = true

  # [Part 1] Docker 설치 스크립트
  part {
    content_type = "text/x-shellscript"
    content      = file("${path.module}/scripts/docker_setup.sh")
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

# 설정 및 컨테이너 실행
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

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = aws_instance.api_server.public_ip
    private_key = file(var.ssh_key_path)
  }

  provisioner "file" {
    content = templatefile("${path.module}/scripts/nginx_setup.sh.tftpl", {
      domain_name    = var.domain_name
      email          = var.cert_email
      conf_file_name = var.nginx_conf_name
    })
    destination = "/tmp/update_nginx.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait > /dev/null", # Docker 설치 대기
      "chmod +x /tmp/update_nginx.sh",
      "echo 'Running Updated Nginx Script...'",
      "sudo /tmp/update_nginx.sh",
      "rm /tmp/update_nginx.sh"
    ]
  }
}

# [리소스 2] Side Infra 설정 변경 감지 및 실행
resource "null_resource" "update_side_infra" {
  depends_on = [aws_instance.api_server]

  triggers = {
    script_hash = sha256(templatefile("${path.module}/scripts/side_infra_setup.sh.tftpl", {
      work_dir               = var.work_dir
      alloy_env_name         = var.alloy_env_name
      alloy_config_content   = var.alloy_config_content
      redis_version          = var.redis_version
      redis_exporter_version = var.redis_exporter_version
      alloy_version          = var.alloy_version
    }))
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = aws_instance.api_server.public_ip
    private_key = file(var.ssh_key_path)
  }

  provisioner "file" {
    content = templatefile("${path.module}/scripts/side_infra_setup.sh.tftpl", {
      work_dir               = var.work_dir
      alloy_env_name         = var.alloy_env_name
      alloy_config_content   = var.alloy_config_content
      redis_version          = var.redis_version
      redis_exporter_version = var.redis_exporter_version
      alloy_version          = var.alloy_version
    })
    destination = "/tmp/update_side_infra.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait > /dev/null", # Docker 설치 대기
      "chmod +x /tmp/update_side_infra.sh",
      "echo 'Running Updated Side Infra Script...'",
      "sudo /tmp/update_side_infra.sh",
      "rm /tmp/update_side_infra.sh"
    ]
  }
}
