variable "env_name" {
  description = "환경 이름"
  type        = string
}

variable "vpc_id" {
  description = "배포할 VPC ID"
  type        = string
}

variable "ami_id" {
  description = "EC2 AMI ID"
  type        = string
}

variable "key_name" {
  description = "EC2 Key Pair 이름"
  type        = string
}

variable "instance_type" {
  description = "EC2 인스턴스 타입"
  type        = string
}

variable "private_ip" {
  description = "alloy 설정을 위한 private ip 고정"
  type = string
}

variable "monitoring_ingress_rules" {
  description = "모니터링 도구(Grafana, Prometheus, Loki)를 위한 보안 규칙"
  type = list(object({
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
    description = string
  }))
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
