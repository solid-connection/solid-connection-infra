module "app" {
  source = "./modules/app"

  env_name                 = var.env_name
  ami_id                   = var.ami_id
  instance_type            = var.instance_type
  api_security_group_id    = aws_security_group.api_sg.id
  ec2_iam_instance_profile = var.ec2_iam_instance_profile
  key_name                 = var.key_name

  domain_name     = var.domain_name
  cert_email      = var.cert_email
  nginx_conf_name = var.nginx_conf_name

  work_dir               = var.work_dir
  alloy_env_name         = var.alloy_env_name
  redis_version          = var.redis_version
  redis_exporter_version = var.redis_exporter_version
  alloy_version          = var.alloy_version
}
