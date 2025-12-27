variable "ami_id" {
  description = "AMI ID for the stage environment"
  type        = string
}

variable "server_instance_type" {
  description = "Server instance type for the stage environment"
  type        = string
}

variable "db_instance_class" {
  description = "DB instance class for the stage environment"
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
  description = "RDS identifier for the stage environment"
  type        = string
}

variable "db_engine_version" {
  description = "MySQL engine version for the stage environment"
  type        = string
}

variable "db_parameter_group_name" {
  description = "MySQL parameter group name for the stage environment"
  type        = string
}

variable "db_root_username" {
  description = "DB Username for stage"
  type        = string
}

variable "db_root_password" {
  description = "DB Password for stage"
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
  description = "Existing KMS Key ARN for stage DB Encryption"
  type        = string
}

variable "domain_name" {
  description = "Domain name for the stage environment"
  type        = string
}

variable "cert_email" {
  description = "email for Domain Name Certbot"
  type        = string
}

variable "nginx_conf_name" {
  description = "Nginx conf name for the stage environment"
  type        = string
}

variable "s3_default_bucket_name" {
  description = "Name of the default S3 bucket"
  type        = string
}

variable "s3_upload_bucket_name" {
  description = "Name of the upload S3 bucket"
  type        = string
}

variable "ssh_key_path" {
  description = "Path to the SSH private key file for remote-exec"
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
