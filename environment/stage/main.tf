# 기본 VPC 정보 조회
data "aws_vpc" "default" {
  default = true
}

module "stage_stack" {
  source = "../../modules/app_stack"

  env_name = "stage"
  vpc_id   = data.aws_vpc.default.id

  ami_id = local.ami_id

  # IAM Instance Profile (SSM + Parameter Store 접근)
  ec2_iam_instance_profile = local.ec2_iam_instance_profile

  # 키페어 및 접속 허용
  key_name = local.key_name

  # 인스턴스 스펙
  instance_type = local.server_instance_type

  # RDS 미사용 (Docker container로 대체)
  enable_rds = false

  # 보안 그룹 규칙
  api_ingress_rules = local.api_ingress_rules

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
