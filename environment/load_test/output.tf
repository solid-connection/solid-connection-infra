output "load_test_rds_endpoint" {
  description = "Load test RDS endpoint"
  value       = aws_db_instance.load_test.address
}

output "load_test_rds_port" {
  description = "Load test RDS port"
  value       = aws_db_instance.load_test.port
}

output "load_test_rds_identifier" {
  description = "Load test RDS identifier"
  value       = aws_db_instance.load_test.identifier
}

output "load_test_db_name" {
  description = "Load test database name"
  value       = var.db_name
}

output "prod_rds_endpoint" {
  description = "Prod RDS endpoint used as dump source"
  value       = data.aws_db_instance.prod.address
}

output "prod_rds_port" {
  description = "Prod RDS port"
  value       = data.aws_db_instance.prod.port
}

output "prod_api_instance_id" {
  description = "Prod API EC2 instance ID whose security group can access load-test RDS"
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

output "prod_db_username_parameter_name" {
  description = "SSM parameter name containing the prod DB username"
  value       = var.prod_db_username_parameter_name
}

output "prod_db_password_parameter_name" {
  description = "SSM SecureString parameter name containing the prod DB password"
  value       = var.prod_db_password_parameter_name
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
