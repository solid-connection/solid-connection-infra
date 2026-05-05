terraform {
  required_version = ">= 1.10.0"

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

  backend "s3" {
    bucket       = "solid-connection-tfstate"
    key          = "env/prod/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
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
  username = local.db_root_username
  password = local.db_root_password
}
