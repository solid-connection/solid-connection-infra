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
# 개발자용 IAM Policy (수동 관리, Terraform은 참조만)
# =============================================

data "aws_iam_policy" "developer_tfstate" {
  name = "TerraformStateAccessPolicy"
}

# =============================================
# GitHub Actions OIDC
# =============================================

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
  tags = {
    Project = "solid-connection"
    Env     = "bootstrap"
  }
}

resource "aws_iam_role" "github_actions" {
  name        = "GitHubActionsTerraformRole"
  description = "IAM Role for GitHub Actions terraform plan/apply via OIDC"
  tags = {
    Project = "solid-connection"
    Env     = "bootstrap"
  }


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
          "token.actions.githubusercontent.com:sub" = [
            "repo:solid-connection/solid-connection-infra:ref:refs/heads/main",
            "repo:solid-connection/solid-connection-infra:pull_request"
          ]
        }
      }
    }]
  })
}

# GitHub Actions 정책 (수동 관리, Terraform은 참조만)
data "aws_iam_policy" "github_actions_tfstate" {
  name = "GitHubActionsTfstatePolicy"
}

data "aws_iam_policy" "github_actions_infra" {
  name = "GitHubActionsTerraformInfraPolicy"
}

resource "aws_iam_role_policy_attachment" "github_actions_tfstate" {
  role       = aws_iam_role.github_actions.name
  policy_arn = data.aws_iam_policy.github_actions_tfstate.arn
}

resource "aws_iam_role_policy_attachment" "github_actions_infra" {
  role       = aws_iam_role.github_actions.name
  policy_arn = data.aws_iam_policy.github_actions_infra.arn
}
