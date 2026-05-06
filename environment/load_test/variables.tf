variable "rds_identifier" {
  description = "RDS identifier for load test"
  type        = string
}

variable "db_instance_class" {
  description = "RDS instance class for load test"
  type        = string
}

variable "allocated_storage" {
  description = "RDS storage in GiB"
  type        = number
  default     = 20
}

variable "db_engine_version" {
  description = "MySQL engine version"
  type        = string
}

variable "db_parameter_group_name" {
  description = "MySQL parameter group name"
  type        = string
}

variable "db_name" {
  description = "Application database name"
  type        = string
  default     = "solid_connection"
}

variable "load_test_db_username_parameter_name" {
  description = "SSM parameter name containing the load test DB root username"
  type        = string
}

variable "load_test_db_password_parameter_name" {
  description = "SSM SecureString parameter name containing the load test DB root password"
  type        = string
}

variable "prod_db_username_parameter_name" {
  description = "SSM parameter name containing the prod DB username"
  type        = string
  default     = "/solid-connection/prod/spring.datasource.username"
}

variable "prod_db_password_parameter_name" {
  description = "SSM SecureString parameter name containing the prod DB password"
  type        = string
  default     = "/solid-connection/prod/spring.datasource.password"
}

variable "kms_key_arn" {
  description = "KMS key ARN for RDS storage encryption"
  type        = string
}

variable "ssm_kms_key_id" {
  description = "KMS key ID or ARN for SSM SecureString. Null uses the AWS managed aws/ssm key."
  type        = string
  default     = null
  nullable    = true
}

variable "prod_rds_identifier" {
  description = "Source prod RDS identifier"
  type        = string
}

variable "prod_api_instance_name" {
  description = "Name tag of the prod API EC2 instance used to run dump/restore"
  type        = string
  default     = "solid-connection-server-prod"
}

variable "stage_api_instance_name" {
  description = "Name tag of the stage API EC2 instance that will connect to load test RDS"
  type        = string
  default     = "solid-connection-server-stage"
}

variable "load_test_parameter_prefix" {
  description = "SSM Parameter Store prefix for load test datasource values"
  type        = string
  default     = "/solid-connection/loadtest"
}
