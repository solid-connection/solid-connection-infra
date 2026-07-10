locals {
  db_user_names = var.enable_rds || var.enable_db_ec2 ? toset(nonsensitive(keys(var.additional_db_users))) : toset([])
}

resource "mysql_user" "users" {
  for_each = local.db_user_names

  user               = each.key
  host               = "%"
  plaintext_password = var.additional_db_users[each.key].password

  depends_on = [
    aws_db_instance.default,
    aws_instance.db_server,
  ]
}

resource "mysql_grant" "user_grants" {
  for_each = local.db_user_names

  user       = each.key
  host       = "%"
  database   = var.additional_db_users[each.key].database
  privileges = var.additional_db_users[each.key].privileges

  depends_on = [mysql_user.users]
}
