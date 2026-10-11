variable "enabled" {
  type    = bool
  default = true
}

variable "env_name" {
  type = string
}

variable "db_instance_type" {
  type    = string
  default = null
}

variable "db_ami_id" {
  type    = string
  default = null
}

variable "db_subnet_id" {
  type    = string
  default = null
}

variable "db_private_ip" {
  type    = string
  default = null
}

variable "data_volume_id" {
  type    = string
  default = null
}

variable "db_security_group_id" {
  type    = string
  default = null
}

variable "alarm_client_security_group_id" {
  type    = string
  default = null
}

variable "ec2_iam_instance_profile" {
  type    = string
  default = null
}

variable "key_name" {
  type = string
}

variable "db_username" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}
