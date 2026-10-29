# app_stack 을 호환 wrapper로 유지하면서 기존 state 주소를 하위 모듈로 이전합니다.
# 이 선언 덕분에 모듈 분리는 실제 EC2나 null_resource를 다시 만들지 않습니다.
moved {
  from = data.aws_instance.monitoring_server
  to   = module.app.data.aws_instance.monitoring_server
}

moved {
  from = data.cloudinit_config.app_init
  to   = module.app.data.cloudinit_config.app_init
}

moved {
  from = aws_instance.api_server
  to   = module.app.aws_instance.api_server
}

moved {
  from = null_resource.install_nginx
  to   = module.app.null_resource.install_nginx
}

moved {
  from = null_resource.update_nginx_conf
  to   = module.app.null_resource.update_nginx_conf
}

moved {
  from = null_resource.update_side_infra
  to   = module.app.null_resource.update_side_infra
}

moved {
  from = data.cloudinit_config.db_init[0]
  to   = module.db_ec2.data.cloudinit_config.db_init[0]
}

moved {
  from = aws_instance.db_server[0]
  to   = module.db_ec2.aws_instance.db_server[0]
}

moved {
  from = aws_volume_attachment.db_data[0]
  to   = module.db_ec2.aws_volume_attachment.db_data[0]
}
