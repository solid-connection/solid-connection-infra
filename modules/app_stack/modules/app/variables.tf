variable "env_name" {
  type = string
}

variable "ami_id" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "api_security_group_id" {
  type = string
}

variable "ec2_iam_instance_profile" {
  type    = string
  default = null
}

variable "key_name" {
  type = string
}

variable "domain_name" {
  type = string
}

variable "cert_email" {
  type = string
}

variable "nginx_conf_name" {
  type = string
}

variable "work_dir" {
  type = string
}

variable "alloy_env_name" {
  type = string
}

variable "redis_version" {
  type = string
}

variable "redis_exporter_version" {
  type = string
}

variable "alloy_version" {
  type = string
}
