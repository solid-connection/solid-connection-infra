output "db_server_private_ip" {
  description = "DB EC2 서버 private IP"
  value       = try(aws_instance.db_server[0].private_ip, null)
}

output "db_server_instance_id" {
  description = "DB EC2 서버 인스턴스 ID"
  value       = try(aws_instance.db_server[0].id, null)
}
