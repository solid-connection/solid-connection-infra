output "load_test_db_endpoint" {
  description = "Load-test MySQL EC2 private endpoint"
  value       = aws_instance.load_test_db.private_ip
}

output "load_test_db_port" {
  description = "Load-test MySQL EC2 port"
  value       = var.load_test_db_port
}

output "load_test_db_instance_id" {
  description = "Load-test MySQL EC2 instance ID"
  value       = aws_instance.load_test_db.id
}

output "load_test_db_private_ip" {
  description = "Load-test MySQL EC2 private IP"
  value       = aws_instance.load_test_db.private_ip
}

output "load_test_db_data_volume_id" {
  description = "Load-test MySQL EC2 data EBS volume ID"
  value       = aws_ebs_volume.load_test_db_data.id
}

output "load_test_db_name" {
  description = "Load test database name"
  value       = var.db_name
}

output "prod_db_instance_id" {
  description = "Prod MySQL EC2 instance ID used as the default AMI source"
  value       = data.aws_instance.prod_db.id
}

output "prod_db_private_ip" {
  description = "Prod MySQL EC2 private IP"
  value       = data.aws_instance.prod_db.private_ip
}

output "prod_api_instance_id" {
  description = "Prod API EC2 instance ID whose security group can access load-test MySQL EC2"
  value       = data.aws_instance.prod_api.id
}

output "stage_api_instance_id" {
  description = "Stage API EC2 instance ID"
  value       = data.aws_instance.stage_api.id
}

output "stage_api_public_ip" {
  description = "Stage API EC2 public IP"
  value       = data.aws_instance.stage_api.public_ip
}

output "load_test_ssm_parameter_prefix" {
  description = "SSM Parameter Store prefix for load test datasource values"
  value       = var.load_test_parameter_prefix
}

output "load_generator_instance_id" {
  description = "k6 load generator EC2 instance ID"
  value       = try(aws_instance.load_generator[0].id, "")
}

output "load_generator_private_ip" {
  description = "k6 load generator private IP"
  value       = try(aws_instance.load_generator[0].private_ip, "")
}

output "load_generator_k6_dir" {
  description = "Directory where k6 files are placed on the load generator"
  value       = var.load_generator_k6_dir
}

output "load_test_target_base_url" {
  description = "Default target base URL for k6"
  value       = var.load_test_target_base_url
}

output "k6_prometheus_remote_write_url" {
  description = "Default Prometheus remote-write URL for k6"
  value       = var.k6_prometheus_remote_write_url
}
