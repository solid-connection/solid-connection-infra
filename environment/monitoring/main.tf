# 기본 VPC 정보 조회
data "aws_vpc" "default" {
  default = true
}

module "monitoring_stack" {
  # 기존 app_stack 모듈을 재사용하거나, 모니터링 전용 모듈이 있다면 경로 수정
  source = "../../modules/monitoring_stack"

  env_name          = "monitoring"
  vpc_id            = data.aws_vpc.default.id

  ami_id            = var.ami_id

  key_name          = var.key_name

  instance_type     = var.monitoring_instance_type

  private_ip = var.private_ip

  # Nginx 및 도메인 설정
  domain_name = var.domain_name
  cert_email  = var.cert_email
  nginx_conf_name = var.nginx_conf_name


  # Grafana(3000), Prometheus(9090), Loki(3100) 포트 개방
  monitoring_ingress_rules = var.monitoring_ingress_rules
}
