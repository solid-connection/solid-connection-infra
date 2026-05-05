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
  description = "Prod API EC2 instance ID used to run migration commands"
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
