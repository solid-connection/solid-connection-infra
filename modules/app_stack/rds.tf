# 5. RDS
resource "aws_db_instance" "default" {
  identifier            = var.rds_identifier
  allocated_storage     = 20
  engine                = "mysql"
  engine_version        = var.db_engine_version
  instance_class        = var.db_instance_class
  username              = var.db_username
  password              = var.db_password
  parameter_group_name  = var.db_parameter_group_name
  copy_tags_to_snapshot = true
  skip_final_snapshot   = true
  vpc_security_group_ids = [aws_security_group.db_sg.id]

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  tags = {
    Name = var.rds_identifier
  }
}

# 6. MySQL 추가 유저 생성
resource "mysql_user" "users" {
  for_each = var.additional_db_users

  user               = each.key
  host               = "%"
  plaintext_password = each.value.password

  depends_on = [aws_db_instance.default]
}

# 7. MySQL 권한 부여
resource "mysql_grant" "user_grants" {
  for_each = var.additional_db_users

  user       = each.key
  host       = "%"
  database   = each.value.database
  privileges = each.value.privileges

  depends_on = [mysql_user.users]
}
