output "tfstate_bucket_arn" {
  value = aws_s3_bucket.tfstate.arn
}

output "tfstate_bucket_name" {
  value = aws_s3_bucket.tfstate.bucket
}

output "developer_tfstate_policy_arn" {
  description = "개발자 IAM 유저에 attach할 tfstate 접근 Policy ARN"
  value       = aws_iam_policy.developer_tfstate.arn
}

output "github_actions_role_arn" {
  description = "GitHub Actions workflow에서 사용할 IAM Role ARN"
  value       = aws_iam_role.github_actions.arn
}
