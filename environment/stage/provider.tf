provider "aws" {
  region = "ap-northeast-2"
  default_tags {
    tags = {
      Project = "solid-connection"
      Env     = "stage"
    }
  }
}