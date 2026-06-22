variable "ec2_iam_instance_profile" {
  description = "EC2에 연결할 IAM Instance Profile 이름"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for the prod environment"
  type        = string
}

variable "server_instance_type" {
  description = "Server instance type for the prod environment"
  type        = string
}

variable "db_instance_class" {
  description = "DB instance class for the prod environment"
  type        = string
}

variable "db_ec2_instance_type" {
  description = "DB EC2 인스턴스 타입"
  type        = string
}

variable "db_ec2_ami_id" {
  description = "DB EC2에 사용할 커스텀 AMI ID"
  type        = string
}

variable "api_ingress_rules" {
  description = "List of ingress rules for API Server"
  type = list(object({
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
    description = string
  }))
}

variable "db_ingress_rules" {
  description = "List of ingress rules for DB Server"
  type = list(object({
    from_port   = number
    to_port     = number
    protocol    = string
    description = string
  }))
}

variable "rds_identifier" {
  description = "RDS identifier for the prod environment"
  type        = string
}

variable "db_engine_version" {
  description = "MySQL engine version for the prod environment"
  type        = string
}

variable "db_parameter_group_name" {
  description = "MySQL parameter group name for the prod environment"
  type        = string
}

variable "db_root_username" {
  description = "DB Username for prod"
  type        = string
}

variable "db_root_password" {
  description = "DB Password for prod"
  type        = string
  sensitive   = true
}

variable "additional_db_users" {
  description = "추가 DB 유저 및 권한 목록"
  type = map(object({
    password   = string
    database   = string
    privileges = list(string)
  }))
}

variable "key_name" {
  description = "Key pair name"
  type        = string
}

variable "kms_key_arn" {
  description = "Existing KMS Key ARN for prod DB Encryption"
  type        = string
}

variable "domain_name" {
  description = "Domain name for the prod environment"
  type        = string
}

variable "cert_email" {
  description = "email for Domain Name Certbot"
  type        = string
}

variable "nginx_conf_name" {
  description = "Nginx conf name for the prod environment"
  type        = string
}

variable "work_dir" {
  description = "Working directory for the application"
  type        = string
}

variable "alloy_env_name" {
  description = "Alloy Env Name"
  type        = string
}

variable "redis_version" {
  description = "Docker image tag for Redis"
  type        = string
}

variable "redis_exporter_version" {
  description = "Docker image tag for Redis Exporter"
  type        = string
}

variable "alloy_version" {
  description = "Docker image tag for Grafana Alloy"
  type        = string
}
