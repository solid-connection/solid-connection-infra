resource "mysql_user" "users" {
  for_each = var.enable_rds || var.enable_db_ec2 ? var.additional_db_users : {}

  user               = each.key
  host               = "%"
  plaintext_password = each.value.password

  depends_on = [
    aws_db_instance.default,
    aws_instance.db_server,
  ]
}

resource "mysql_grant" "user_grants" {
  for_each = var.enable_rds || var.enable_db_ec2 ? var.additional_db_users : {}

  user       = each.key
  host       = "%"
  database   = each.value.database
  privileges = each.value.privileges

  depends_on = [mysql_user.users]
}
