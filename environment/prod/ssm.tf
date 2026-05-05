locals {
  prod_parameter_prefix      = "/solid-connection/infra/prod"
  app_stack_parameter_prefix = "/solid-connection/infra/common/app-stack"
}

data "aws_ssm_parameter" "ami_id" {
  name = "${local.prod_parameter_prefix}/ami-id"
}

data "aws_ssm_parameter" "server_instance_type" {
  name = "${local.prod_parameter_prefix}/server-instance-type"
}

data "aws_ssm_parameter" "db_instance_class" {
  name = "${local.prod_parameter_prefix}/db-instance-class"
}

data "aws_ssm_parameter" "rds_identifier" {
  name = "${local.prod_parameter_prefix}/rds-identifier"
}

data "aws_ssm_parameter" "db_engine_version" {
  name = "${local.prod_parameter_prefix}/db-engine-version"
}

data "aws_ssm_parameter" "db_parameter_group_name" {
  name = "${local.prod_parameter_prefix}/db-parameter-group-name"
}

data "aws_ssm_parameter" "db_root_username" {
  name = "${local.prod_parameter_prefix}/db-root-username"
}

data "aws_ssm_parameter" "db_root_password" {
  name            = "${local.prod_parameter_prefix}/db-root-password"
  with_decryption = true
}

data "aws_ssm_parameter" "additional_db_users" {
  name            = "${local.prod_parameter_prefix}/additional-db-users"
  with_decryption = true
}

data "aws_ssm_parameter" "key_name" {
  name = "${local.prod_parameter_prefix}/key-name"
}

data "aws_ssm_parameter" "kms_key_arn" {
  name = "${local.prod_parameter_prefix}/kms-key-arn"
}

data "aws_ssm_parameter" "domain_name" {
  name = "${local.prod_parameter_prefix}/domain-name"
}

data "aws_ssm_parameter" "cert_email" {
  name = "${local.prod_parameter_prefix}/cert-email"
}

data "aws_ssm_parameter" "nginx_conf_name" {
  name = "${local.prod_parameter_prefix}/nginx-conf-name"
}

data "aws_ssm_parameter" "ssh_key_path" {
  name = "${local.prod_parameter_prefix}/ssh-key-path"
}

data "aws_ssm_parameter" "work_dir" {
  name = "${local.prod_parameter_prefix}/work-dir"
}

data "aws_ssm_parameter" "alloy_env_name" {
  name = "${local.prod_parameter_prefix}/alloy-env-name"
}

data "aws_ssm_parameter" "api_ingress_rules" {
  name = "${local.app_stack_parameter_prefix}/api-ingress-rules"
}

data "aws_ssm_parameter" "ec2_iam_instance_profile" {
  name = "${local.app_stack_parameter_prefix}/ec2-iam-instance-profile"
}

data "aws_ssm_parameter" "db_ingress_rules" {
  name = "${local.app_stack_parameter_prefix}/db-ingress-rules"
}

data "aws_ssm_parameter" "redis_version" {
  name = "${local.app_stack_parameter_prefix}/redis-version"
}

data "aws_ssm_parameter" "redis_exporter_version" {
  name = "${local.app_stack_parameter_prefix}/redis-exporter-version"
}

data "aws_ssm_parameter" "alloy_version" {
  name = "${local.app_stack_parameter_prefix}/alloy-version"
}

locals {
  ami_id                   = data.aws_ssm_parameter.ami_id.value
  server_instance_type     = data.aws_ssm_parameter.server_instance_type.value
  db_instance_class        = data.aws_ssm_parameter.db_instance_class.value
  rds_identifier           = data.aws_ssm_parameter.rds_identifier.value
  db_engine_version        = data.aws_ssm_parameter.db_engine_version.value
  db_parameter_group_name  = data.aws_ssm_parameter.db_parameter_group_name.value
  db_root_username         = data.aws_ssm_parameter.db_root_username.value
  db_root_password         = sensitive(data.aws_ssm_parameter.db_root_password.value)
  additional_db_users      = nonsensitive(jsondecode(data.aws_ssm_parameter.additional_db_users.value))
  key_name                 = data.aws_ssm_parameter.key_name.value
  kms_key_arn              = data.aws_ssm_parameter.kms_key_arn.value
  domain_name              = data.aws_ssm_parameter.domain_name.value
  cert_email               = data.aws_ssm_parameter.cert_email.value
  nginx_conf_name          = data.aws_ssm_parameter.nginx_conf_name.value
  ssh_key_path             = data.aws_ssm_parameter.ssh_key_path.value
  work_dir                 = data.aws_ssm_parameter.work_dir.value
  alloy_env_name           = data.aws_ssm_parameter.alloy_env_name.value
  api_ingress_rules        = jsondecode(data.aws_ssm_parameter.api_ingress_rules.value)
  ec2_iam_instance_profile = data.aws_ssm_parameter.ec2_iam_instance_profile.value
  db_ingress_rules         = jsondecode(data.aws_ssm_parameter.db_ingress_rules.value)
  redis_version            = data.aws_ssm_parameter.redis_version.value
  redis_exporter_version   = data.aws_ssm_parameter.redis_exporter_version.value
  alloy_version            = data.aws_ssm_parameter.alloy_version.value
}
