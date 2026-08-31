variable "rds_identifier" {
  description = "Deprecated. RDS 기반 부하 테스트 DB 식별자 호환 입력입니다."
  type        = string
  default     = null
  nullable    = true
}

variable "db_instance_class" {
  description = "Deprecated. RDS 기반 부하 테스트 DB 인스턴스 클래스 호환 입력입니다."
  type        = string
  default     = null
  nullable    = true
}

variable "allocated_storage" {
  description = "Load-test MySQL EC2 데이터 EBS 볼륨 크기(GiB)입니다."
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage >= 1
    error_message = "allocated_storage는 1GiB 이상이어야 합니다."
  }
}

variable "db_engine_version" {
  description = "Deprecated. RDS 기반 부하 테스트 DB 엔진 버전 호환 입력입니다."
  type        = string
  default     = null
  nullable    = true
}

variable "db_parameter_group_name" {
  description = "Deprecated. RDS 기반 부하 테스트 DB 파라미터 그룹 호환 입력입니다."
  type        = string
  default     = null
  nullable    = true
}

variable "db_name" {
  description = "부하 테스트 대상 애플리케이션 DB 이름입니다."
  type        = string
  default     = "solid_connection"
}

variable "load_test_db_port" {
  description = "Load-test MySQL EC2 listener port."
  type        = number
  default     = 3306

  validation {
    condition     = var.load_test_db_port == floor(var.load_test_db_port) && var.load_test_db_port >= 1 && var.load_test_db_port <= 65535
    error_message = "load_test_db_port must be an integer between 1 and 65535."
  }
}

variable "load_test_db_username_parameter_name" {
  description = "Deprecated. datasource username은 load-test Parameter Store 경로에서 직접 읽습니다."
  type        = string
  default     = null
  nullable    = true
}

variable "load_test_db_password_parameter_name" {
  description = "Deprecated. datasource password는 load-test Parameter Store 경로에서 직접 읽습니다."
  type        = string
  default     = null
  nullable    = true
}

variable "kms_key_arn" {
  description = "Deprecated. RDS 기반 부하 테스트 DB 스토리지 암호화 KMS ARN 호환 입력입니다."
  type        = string
  default     = null
  nullable    = true
}

variable "ssm_kms_key_id" {
  description = "Deprecated. Terraform은 더 이상 load-test DB password SecureString을 작성하지 않습니다."
  type        = string
  default     = null
  nullable    = true
}

variable "prod_rds_identifier" {
  description = "Deprecated. RDS snapshot 조회용 prod RDS identifier 호환 입력입니다."
  type        = string
  default     = null
  nullable    = true
}

variable "prod_db_instance_name" {
  description = "prod MySQL EC2의 Name tag입니다. load-test DB AMI 기본값을 조회할 때 사용합니다."
  type        = string
  default     = "solid-connection-db-mysql-prod"
}

variable "load_test_db_instance_name" {
  description = "load-test MySQL EC2에 부여할 Name tag입니다."
  type        = string
  default     = "solid-connection-db-mysql-loadtest"
}

variable "load_test_db_instance_type" {
  description = "load-test MySQL EC2 인스턴스 타입입니다."
  type        = string
  default     = "t4g.medium"
}

variable "load_test_db_ami_id" {
  description = "load-test MySQL EC2 AMI ID입니다. null이면 prod MySQL EC2의 AMI를 사용합니다."
  type        = string
  default     = "ami-0501a03cd31b53e82"
  nullable    = true
}

variable "load_test_db_subnet_id" {
  description = "load-test MySQL EC2를 배치할 subnet ID입니다. null이면 prod DB EC2와 같은 subnet을 사용합니다."
  type        = string
  default     = null
  nullable    = true
}

variable "load_test_db_associate_public_ip" {
  description = "load-test MySQL EC2 public IP 할당 여부입니다."
  type        = bool
  default     = false
}

variable "load_test_db_instance_profile_name" {
  description = "사전에 생성된 load-test MySQL EC2 전용 IAM instance profile 이름입니다. Terraform은 IAM을 생성하지 않고 이 이름만 EC2에 연결합니다."
  type        = string
  default     = "solid-connection-load-test-db"
}

variable "mysql_backup_bucket_name" {
  description = "prod MySQL dump manifest와 dump 파일을 읽을 S3 bucket 이름입니다."
  type        = string
  default     = "solid-connection-prod-mysql-backup"
}

variable "prod_api_instance_name" {
  description = "load-test MySQL EC2에 접근할 prod API EC2의 Name tag입니다."
  type        = string
  default     = "solid-connection-server-prod"
}

variable "stage_api_instance_name" {
  description = "load-test MySQL EC2에 접근하고 loadtest profile로 전환할 stage API EC2의 Name tag입니다."
  type        = string
  default     = "solid-connection-server-stage"
}

variable "load_test_parameter_prefix" {
  description = "load-test datasource 값을 기록하거나 읽을 SSM Parameter Store prefix입니다."
  type        = string
  default     = "/solid-connection/loadtest"
}

variable "load_generator_instance_type" {
  description = "k6 load-generator EC2 인스턴스 타입입니다."
  type        = string
  default     = "c7i.xlarge"
}

variable "create_load_generator" {
  description = "k6 load-generator EC2 생성 여부입니다."
  type        = bool
  default     = false
}

variable "load_generator_instance_profile_name" {
  description = "k6 load-generator EC2에 연결할 IAM instance profile 이름입니다. SSM RunCommand 권한이 필요합니다."
  type        = string
  default     = "solid-connection-load-test-generator"
}

variable "load_generator_root_volume_size" {
  description = "k6 load-generator EC2 root volume 크기(GiB)입니다."
  type        = number
  default     = 20
}

variable "load_generator_k6_dir" {
  description = "load-generator EC2에 k6 파일을 배치할 디렉터리입니다."
  type        = string
  default     = "/home/ubuntu/solid-connection-load-test/k6"
}

variable "load_test_target_base_url" {
  description = "k6가 호출할 기본 target base URL입니다."
  type        = string
  default     = "https://api.stage.solid-connection.com"
}

variable "k6_prometheus_remote_write_url" {
  description = "k6 Prometheus remote-write URL입니다. 빈 값이면 workflow 입력값이 없을 때 remote-write를 비활성화합니다."
  type        = string
  default     = ""
}
