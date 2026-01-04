terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# 인증서 발급용 리전 (버지니아 북부)
provider "aws" {
  alias  = "virginia"
  region = "us-east-1"
}