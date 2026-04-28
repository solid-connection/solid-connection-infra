variable "ami_id" {
  description = "AMI ID for the stage environment"
  type        = string
}

variable "server_instance_type" {
  description = "Server instance type for the stage environment"
  type        = string
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

variable "key_name" {
  description = "Key pair name"
  type        = string
}

variable "domain_name" {
  description = "Domain name for the stage environment"
  type        = string
}

variable "cert_email" {
  description = "email for Domain Name Certbot"
  type        = string
}

variable "nginx_conf_name" {
  description = "Nginx conf name for the stage environment"
  type        = string
}

variable "ssh_key_path" {
  description = "Path to the SSH private key file for remote-exec"
  type        = string
}

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
