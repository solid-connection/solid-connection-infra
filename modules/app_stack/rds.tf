resource "aws_db_instance" "default" {
  count = var.enable_rds ? 1 : 0

  identifier             = var.rds_identifier
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = var.db_engine_version
  instance_class         = var.db_instance_class
  username               = var.db_username
  password               = var.db_password
  parameter_group_name   = var.db_parameter_group_name
  copy_tags_to_snapshot  = true
  skip_final_snapshot    = true
  vpc_security_group_ids = [aws_security_group.db_sg[count.index].id]

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  tags = {
    Name = var.rds_identifier
  }
}
