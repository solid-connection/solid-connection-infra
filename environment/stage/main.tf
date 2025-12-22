data "aws_vpc" "default" {
  default = true
}

module "stage_stack" {
  source = "../../modules/app_stack"

  env_name          = "stage"
  vpc_id            = data.aws_vpc.default.id

  # 키페어 및 접속 허용
  key_name          = var.key_name
  
  # DB 계정 정보
  db_username       = var.db_username
  db_password       = var.db_password 

  # DB 엔진 및 암호화 설정
  kms_key_arn       = var.kms_key_arn
}