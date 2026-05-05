locals {
  parameter_prefix = "/solid-connection/infra/monitoring"
}

data "aws_ssm_parameter" "ami_id" {
  name = "${local.parameter_prefix}/ami-id"
}

data "aws_ssm_parameter" "monitoring_instance_type" {
  name = "${local.parameter_prefix}/monitoring-instance-type"
}

data "aws_ssm_parameter" "key_name" {
  name = "${local.parameter_prefix}/key-name"
}

data "aws_ssm_parameter" "private_ip" {
  name = "${local.parameter_prefix}/private-ip"
}

data "aws_ssm_parameter" "domain_name" {
  name = "${local.parameter_prefix}/domain-name"
}

data "aws_ssm_parameter" "cert_email" {
  name = "${local.parameter_prefix}/cert-email"
}

data "aws_ssm_parameter" "nginx_conf_name" {
  name = "${local.parameter_prefix}/nginx-conf-name"
}

data "aws_ssm_parameter" "monitoring_ingress_rules" {
  name = "${local.parameter_prefix}/monitoring-ingress-rules"
}

locals {
  ami_id                   = data.aws_ssm_parameter.ami_id.value
  monitoring_instance_type = data.aws_ssm_parameter.monitoring_instance_type.value
  key_name                 = data.aws_ssm_parameter.key_name.value
  private_ip               = data.aws_ssm_parameter.private_ip.value
  domain_name              = data.aws_ssm_parameter.domain_name.value
  cert_email               = data.aws_ssm_parameter.cert_email.value
  nginx_conf_name          = data.aws_ssm_parameter.nginx_conf_name.value
  monitoring_ingress_rules = jsondecode(data.aws_ssm_parameter.monitoring_ingress_rules.value)
}
