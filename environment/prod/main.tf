# 기본 VPC 정보 조회
data "aws_vpc" "default" {
  default = true
}

module "prod_stack" {
  source = "../../modules/app_stack"

  env_name          = "prod"
  vpc_id            = data.aws_vpc.default.id

  ami_id = var.ami_id

  # 키페어 및 접속 허용
  key_name          = var.key_name
  
  # 인스턴스 스펙
  instance_type     = var.server_instance_type
  db_instance_class = var.db_instance_class

  # 보안 그룹 규칙
  api_ingress_rules = var.api_ingress_rules
  db_ingress_rules  = var.db_ingress_rules

  # RDS 식별자 설정
  rds_identifier = var.rds_identifier
  
  # DB 계정 정보
  db_username       = var.db_root_username
  db_password       = var.db_root_password

  # DB 엔진 및 암호화 설정
  db_engine_version = var.db_engine_version             # MySQL 버전 지정
  db_parameter_group_name = var.db_parameter_group_name # MySQL 파라미터 그룹 지정
  kms_key_arn       = var.kms_key_arn                   # KMS ARN 변수 전달

  # 추가 유저마다 다른 권한 부여
  additional_db_users = var.additional_db_users

  # Nginx 및 도메인 설정
  domain_name = var.domain_name
  cert_email  = var.cert_email
  nginx_conf_name = var.nginx_conf_name

  # S3 버킷 이름 전달
  s3_default_bucket_name = var.s3_default_bucket_name
  s3_upload_bucket_name  = var.s3_upload_bucket_name
}
