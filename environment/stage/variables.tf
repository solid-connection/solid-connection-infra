variable "kms_key_arn" {
  description = "Existing KMS Key ARN for stage DB Encryption"
  type        = string
}

variable "db_username" {
  description = "DB Username for stage"
  type        = string
}

variable "db_password" {
  description = "DB Password from secret"
  type        = string
  sensitive   = true
}

variable "key_name" {
  description = "Key pair name"
  type        = string
}