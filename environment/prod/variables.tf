variable "kms_key_arn" {
  description = "Existing KMS Key ARN for prod DB Encryption"
  type        = string
}

variable "db_username" {
  description = "DB Username for prod"
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