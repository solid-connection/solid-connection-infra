output "monitoring_instance_public_ip" {
  value = aws_instance.monitoring_server.public_ip
}

output "monitoring_sg_id" {
  value = aws_security_group.monitoring_sg.id
}
