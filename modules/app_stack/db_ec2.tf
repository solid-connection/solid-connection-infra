data "aws_subnet" "db_ec2" {
  count = var.enable_db_ec2 ? 1 : 0

  id = var.db_subnet_id
}

# 운영 데이터 볼륨은 app_stack 에 남겨 기존 state 주소와 prevent_destroy 보호를 유지합니다.
# 재사용 가능한 db_ec2 모듈은 전달받은 볼륨을 DB EC2에 연결하는 역할만 담당합니다.
resource "aws_ebs_volume" "db_data" {
  count = var.enable_db_ec2 ? 1 : 0

  availability_zone = data.aws_subnet.db_ec2[count.index].availability_zone
  size              = var.db_data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "solid-connection-db-mysql-data-${var.env_name}"
  }

  lifecycle {
    prevent_destroy = true
  }
}

module "db_ec2" {
  source = "./modules/db_ec2"

  enabled                        = var.enable_db_ec2
  env_name                       = var.env_name
  db_instance_type               = var.db_instance_type
  db_ami_id                      = var.db_ami_id
  db_subnet_id                   = var.db_subnet_id
  db_private_ip                  = var.db_private_ip
  data_volume_id                 = try(aws_ebs_volume.db_data[0].id, null)
  db_security_group_id           = try(aws_security_group.db_ec2_sg[0].id, null)
  alarm_client_security_group_id = try(aws_security_group.db_ec2_alarm_client_sg[0].id, null)
  ec2_iam_instance_profile       = var.ec2_iam_instance_profile
  key_name                       = var.key_name
  db_username                    = var.db_username
  db_password                    = var.db_password
}
