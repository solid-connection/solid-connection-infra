data "aws_caller_identity" "current" {}

# =============================================
# EC2 공유 IAM Role에 SSM 정책 부착
# =============================================

data "aws_iam_role" "ec2_shared" {
  name = "SolidConnectionParameterStoreReadRole"
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = data.aws_iam_role.ec2_shared.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# =============================================
# 개발자용 IAM Policy
# =============================================

# 로컬 terraform plan용: tfstate 읽기 + tflock 쓰기
resource "aws_iam_policy" "developer_tfstate" {
  name        = "TerraformStateAccessPolicy"
  description = "For local terraform plan: read tfstate + write/delete tflock"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.tfstate.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.tfstate.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.tfstate.arn}/*.tfstate.tflock"
      }
    ]
  })
}

# =============================================
# GitHub Actions OIDC
# =============================================

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  name        = "GitHubActionsTerraformRole"
  description = "IAM Role for GitHub Actions terraform plan/apply via OIDC"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:solid-connection/solid-connection-infra:*"
        }
      }
    }]
  })
}

# GitHub Actions: tfstate 버킷 전체 접근
resource "aws_iam_policy" "github_actions_tfstate" {
  name        = "GitHubActionsTfstatePolicy"
  description = "For GitHub Actions terraform apply: full access to tfstate bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ]
      Resource = [
        aws_s3_bucket.tfstate.arn,
        "${aws_s3_bucket.tfstate.arn}/*"
      ]
    }]
  })
}

# GitHub Actions: AWS 인프라 관리 (terraform apply)
resource "aws_iam_policy" "github_actions_infra" {
  name        = "GitHubActionsTerraformInfraPolicy"
  description = "For GitHub Actions terraform apply: AWS infrastructure management"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:*",
          "rds:*",
          "s3:*",
          "cloudfront:*",
          "lambda:*",
          "acm:*",
          "ssm:StartSession",
          "ssm:TerminateSession",
          "ssm:DescribeSessions",
          "ssm:GetConnectionStatus",
          "ssm:DescribeInstanceInformation",
          "kms:DescribeKey",
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:CreateGrant",
          "iam:PassRole",
          "iam:GetRole",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:DescribeLogGroups",
          "logs:ListTagsLogGroup",
          "logs:PutRetentionPolicy"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_tfstate" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_tfstate.arn
}

resource "aws_iam_role_policy_attachment" "github_actions_infra" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_infra.arn
}
