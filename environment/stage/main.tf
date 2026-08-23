# 기본 VPC 정보 조회
data "aws_vpc" "default" {
  default = true
}

module "stage_stack" {
  source = "../../modules/app_stack"

  # stage 는 DB 가 API 인스턴스의 컨테이너로 떠 있어 별도 DB EC2 가 없다.
  # enable_db_ec2 가 false 라 알림 인그레스가 생성되지 않으므로 빈 목록을 넘긴다.
  internal_alarm_api_ports            = []
  internal_alarm_api_management_ports = []

  env_name = "stage"
  vpc_id   = data.aws_vpc.default.id

  ami_id = var.ami_id

  # IAM Instance Profile (SSM + Parameter Store 접근)
  ec2_iam_instance_profile = var.ec2_iam_instance_profile

  # 키페어 및 접속 허용
  key_name = var.key_name

  # 인스턴스 스펙
  instance_type = var.server_instance_type

  # 보안 그룹 규칙
  api_ingress_rules = var.api_ingress_rules

  # Nginx 및 도메인 설정
  domain_name     = var.domain_name
  cert_email      = var.cert_email
  nginx_conf_name = var.nginx_conf_name

  # Side Infra 관련 변수 전달
  work_dir       = var.work_dir
  alloy_env_name = var.alloy_env_name

  redis_version          = var.redis_version
  redis_exporter_version = var.redis_exporter_version
  alloy_version          = var.alloy_version
}
