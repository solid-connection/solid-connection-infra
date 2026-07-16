output "mysql_backup_bucket_name" {
  description = "Prod MySQL 백업 S3 버킷 이름"
  value       = aws_s3_bucket.mysql_backup.bucket
}

output "mysql_backup_s3_vpc_endpoint_id" {
  description = "Prod MySQL 백업용 S3 Gateway VPC Endpoint ID"
  value       = aws_vpc_endpoint.mysql_backup_s3.id
}
