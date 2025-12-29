variable "ami_id" {
  description = "AMI ID for the monitoring environment"
  type        = string
}

variable "monitoring_instance_type" {
  description = "Instance type for monitoring (e.g., t3.medium or larger recommended)"
  type        = string
}

variable "key_name" {
  description = "SSH Key pair name"
  type        = string
}

variable "monitoring_ingress_rules" {
  description = "Ingress rules for Grafana(3000), Prometheus(9090), Loki(3100)"
  type = list(object({
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
    description = string
  }))
}

variable "private_ip" {
  description = "Fixed private ip for alloy config"
  type = string
}

variable "ebs_volume_size" {
  description = "Disk size for Prometheus TSDB (GB)"
  type        = number
  default     = 50
}

variable "domain_name" {
  description = "Domain name for Grafana dashboard (e.g., monitor.example.com)"
  type        = string
}

variable "cert_email" {
  description = "email for Domain Name Certbot"
  type        = string
}

variable "nginx_conf_name" {
  description = "Nginx conf name for the prod environment"
  type        = string
}
