variable "env_name" {
  description = "환경 이름 (prod/stage)"
}

variable "instance_type" {
  description = "EC2 인스턴스 타입"
}

variable "enable_rds" {
  description = "RDS 사용 여부"
  type        = bool
  default     = true
}

variable "enable_db_ec2" {
  description = "DB EC2 사용 여부"
  type        = bool
  default     = false
}

variable "db_instance_type" {
  description = "DB EC2 인스턴스 타입"
  type        = string
  default     = null
}

variable "db_ami_id" {
  description = "DB EC2에 사용할 커스텀 AMI ID"
  type        = string
  default     = null
}

variable "db_subnet_id" {
  description = "DB EC2를 배치할 Private Subnet ID"
  type        = string
  default     = null
}

variable "db_data_volume_size" {
  description = "DB EC2 MySQL data volume 크기 (GiB)"
  type        = number
  default     = null

  validation {
    condition     = !var.enable_db_ec2 || var.db_data_volume_size != null
    error_message = "enable_db_ec2가 true이면 db_data_volume_size를 지정해야 합니다."
  }

  validation {
    condition     = var.db_data_volume_size == null || var.db_data_volume_size >= 1
    error_message = "db_data_volume_size는 1GiB 이상이어야 합니다."
  }
}

variable "ec2_iam_instance_profile" {
  description = "EC2에 연결할 IAM Instance Profile 이름"
  type        = string
  default     = null
}

variable "db_instance_class" {
  description = "RDS 인스턴스 타입"
  default     = null
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
  default = []
}

# [DB 관련 추가 변수]
variable "db_username" {
  description = "DB 마스터 사용자명"
  type        = string
  default     = ""
}

variable "db_password" {
  description = "DB 마스터 비밀번호"
  type        = string
  sensitive   = true
  default     = ""
}

# 추가할 DB 유저 목록
variable "additional_db_users" {
  description = "추가 DB 유저 설정 (비번, 대상 DB, 권한 목록)"
  type = map(object({
    password   = string
    database   = string
    privileges = list(string)
  }))
  default = {}
}

variable "db_engine_version" {
  description = "MySQL 엔진 버전"
  type        = string
  default     = null
}

variable "db_parameter_group_name" {
  description = "MySQL 엔진 파라미터 그룹"
  type        = string
  default     = null
}

variable "rds_identifier" {
  description = "RDS DB Identifier"
  type        = string
  default     = null
}

variable "kms_key_arn" {
  description = "RDS 스토리지 암호화를 위한 KMS Key ARN"
  type        = string
  default     = null
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
