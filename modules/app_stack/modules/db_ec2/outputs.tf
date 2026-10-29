output "private_ip" {
  value = try(aws_instance.db_server[0].private_ip, null)
}

output "instance_id" {
  value = try(aws_instance.db_server[0].id, null)
}
