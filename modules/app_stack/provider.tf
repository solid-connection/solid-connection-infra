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
