resource "aws_security_group" "monitoring_sg" {
  name        = "sc-${var.env_name}-sg"
  description = "Security group for Monitoring Stack (Grafana, Prometheus, Loki)"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.monitoring_ingress_rules
    content {
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
      description = ingress.value.description
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.env_name}-sg"
  }
}
