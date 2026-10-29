# L3 템플릿 렌더링 fixture
#
# user_data / SSM 으로 서버에서 실행되는 .tftpl 을 실제 호출부와 같은 변수 이름으로 렌더링해
# scripts/verify/l3.sh 가 shellcheck 등으로 검사할 수 있게 한다.
# - 이 구성은 provider/backend 가 없으며 terraform console 로만 평가한다. (apply 하지 않음)
# - 템플릿에 변수가 추가되면 여기에도 추가해야 렌더링이 성공한다.
# - 새 .tftpl 을 추가하면 rendered 에 항목을 추가한다.

locals {
  repo = "${path.module}/../../.."

  mysql_tuning = file("${local.repo}/modules/app_stack/templates/mysql_tuning.cnf")

  alloy_config = templatefile("${local.repo}/config/side-infra/config.alloy.tftpl", {
    loki_ip = "10.0.0.10"
  })

  rendered = {
    # modules/app_stack/db_ec2.tf
    "app_stack-mysql_setup.sh" = templatefile("${local.repo}/modules/app_stack/scripts/mysql_setup.sh.tftpl", {
      db_root_username_b64 = base64encode("admin")
      db_root_password_b64 = base64encode("verify-password")
      db_data_volume_id    = "vol-0123456789abcdef0"
      mysql_config_content = local.mysql_tuning
    })

    # modules/app_stack/ec2.tf
    "app_stack-nginx_install.sh" = templatefile("${local.repo}/modules/app_stack/scripts/nginx_install.sh.tftpl", {
      domain_name    = "api.example.com"
      email          = "verify@example.com"
      conf_file_name = "api.conf"
    })
    "app_stack-nginx_conf.sh" = templatefile("${local.repo}/modules/app_stack/scripts/nginx_conf.sh.tftpl", {
      domain_name    = "api.example.com"
      conf_file_name = "api.conf"
    })
    "app_stack-side_infra_setup.sh" = templatefile("${local.repo}/modules/app_stack/scripts/side_infra_setup.sh.tftpl", {
      work_dir               = "/home/ubuntu/side-infra"
      alloy_env_name         = "verify"
      alloy_config_content   = local.alloy_config
      redis_version          = "7.2"
      redis_exporter_version = "v1.62.0"
      alloy_version          = "v1.4.0"
    })

    # modules/monitoring_stack/ec2.tf
    "monitoring_stack-nginx_setup.sh" = templatefile("${local.repo}/modules/monitoring_stack/scripts/nginx_setup.sh.tftpl", {
      domain_name    = "monitoring.example.com"
      email          = "verify@example.com"
      conf_file_name = "monitoring.conf"
    })

    # environment/load_test/main.tf
    "load_test-mysql_setup.sh" = templatefile("${local.repo}/environment/load_test/templates/load_test_mysql_setup.sh.tftpl", {
      aws_region                 = "ap-northeast-2"
      data_volume_id             = "vol-0123456789abcdef0"
      db_name                    = "verify"
      db_port                    = 3306
      ec2messages_endpoint_host  = "vpce-0-ec2messages.ap-northeast-2.vpce.amazonaws.com"
      load_test_parameter_prefix = "/solid-connection/load-test"
      mysql_backup_bucket_name   = "verify-mysql-backup"
      mysql_config_content       = local.mysql_tuning
      ssm_endpoint_host          = "vpce-0-ssm.ap-northeast-2.vpce.amazonaws.com"
      ssmmessages_endpoint_host  = "vpce-0-ssmmessages.ap-northeast-2.vpce.amazonaws.com"
    })
  }
}
