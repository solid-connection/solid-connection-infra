terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
    mysql = {
      source  = "petoju/mysql"
      version = ">= 3.0"
    }
  }
}

# MySQL Provider 설정 (SSH 터널링을 통해 로컬호스트로 접속 가정)
provider "mysql" {
  endpoint = "127.0.0.1:3306"
  username = var.db_username
  password = var.db_password
}
