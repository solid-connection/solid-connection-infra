variable "env_name" {
  description = "환경 이름 (prod/stage)"
}

variable "instance_type" {
  description = "EC2 인스턴스 타입"
}

variable "db_instance_class" {
  description = "RDS 인스턴스 타입"
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

# [DB 관련 추가 변수]
variable "db_username" {
  description = "DB 마스터 사용자명"
  type        = string
}

variable "db_password" {
  description = "DB 마스터 비밀번호"
  type        = string
  sensitive   = true
}

# 추가할 DB 유저 목록
variable "additional_db_users" {
  description = "추가 DB 유저 설정 (비번, 대상 DB, 권한 목록)"
  type = map(object({
    password   = string
    database   = string
    privileges = list(string)
  }))
  default   = {}
}

variable "db_engine_version" {
  description = "MySQL 엔진 버전"
  type        = string
}

variable "db_parameter_group_name" {
  description = "MySQL 엔진 파라미터 그룹"
  type        = string
}

variable "rds_identifier" {
  description = "RDS DB Identifier"
  type        = string
}

variable "kms_key_arn" {
  description = "RDS 스토리지 암호화를 위한 KMS Key ARN"
  type        = string
}

variable "vpc_id" {
  description = "배포할 VPC ID"
}

variable "ami_id" {
  description = "EC2 AMI ID"
  type        = string
}

variable "key_name" {
  description = "AWS 콘솔에 등록된 기존 EC2 Key Pair 이름"
  type        = string
}

# [Nginx 관련 추가 변수]
variable "domain_name" {
  description = "Domain name for Nginx"
  type        = string
}

variable "cert_email" {
  description = "Email for Let's Encrypt"
  type        = string
}

variable "nginx_conf_name" {
  description = "Nginx config filename"
  type        = string
}

# [S3 버킷 관련 변수]
variable "s3_default_bucket_name" {
  description = "Name of the default S3 bucket"
  type        = string
}

variable "s3_upload_bucket_name" {
  description = "Name of the upload S3 bucket"
  type        = string
}

# [Remote SSH용 변수]
variable "ssh_key_path" {
  description = "Path to the SSH private key file for remote-exec"
  type        = string
}

# [Side Infrastructure 관련 변수]
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
