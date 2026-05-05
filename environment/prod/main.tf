# 기본 VPC 정보 조회
data "aws_vpc" "default" {
  default = true
}

module "prod_stack" {
  source = "../../modules/app_stack"

  env_name = "prod"
  vpc_id   = data.aws_vpc.default.id

  ami_id = local.ami_id

  # IAM Instance Profile (SSM + Parameter Store 접근)
  ec2_iam_instance_profile = local.ec2_iam_instance_profile

  # 키페어 및 접속 허용
  key_name = local.key_name

  # 인스턴스 스펙
  instance_type     = local.server_instance_type
  db_instance_class = local.db_instance_class

  # 보안 그룹 규칙
  api_ingress_rules = local.api_ingress_rules
  db_ingress_rules  = local.db_ingress_rules

  # RDS 식별자 설정
  rds_identifier = local.rds_identifier

  # DB 계정 정보
  db_username = local.db_root_username
  db_password = local.db_root_password

  # DB 엔진 및 암호화 설정
  db_engine_version       = local.db_engine_version       # MySQL 버전 지정
  db_parameter_group_name = local.db_parameter_group_name # MySQL 파라미터 그룹 지정
  kms_key_arn             = local.kms_key_arn             # KMS ARN 변수 전달

  # 추가 유저마다 다른 권한 부여
  additional_db_users = local.additional_db_users

  # Nginx 및 도메인 설정
  domain_name     = local.domain_name
  cert_email      = local.cert_email
  nginx_conf_name = local.nginx_conf_name

  # ssh key 경로 전달
  ssh_key_path = local.ssh_key_path

  # Side Infra 관련 변수 전달
  work_dir       = local.work_dir
  alloy_env_name = local.alloy_env_name

  redis_version          = local.redis_version
  redis_exporter_version = local.redis_exporter_version
  alloy_version          = local.alloy_version
}
