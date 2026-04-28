terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    mysql = {
      source  = "petoju/mysql"
      version = ">= 3.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
  default_tags {
    tags = {
      Project = "solid-connection"
      Env     = "prod"
    }
  }
}

# MySQL Provider 설정 (SSH 터널링을 통해 로컬호스트로 접속)
provider "mysql" {
  endpoint = "127.0.0.1:3306"
  username = var.db_root_username
  password = var.db_root_password
}
