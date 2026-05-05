locals {
  parameter_prefix = "/solid-connection/infra/global"
}

data "aws_ssm_parameter" "s3_upload_bucket_name" {
  name = "${local.parameter_prefix}/s3-upload-bucket-name"
}

data "aws_ssm_parameter" "upload_cdn_web_acl_id" {
  name = "${local.parameter_prefix}/upload-cdn-web-acl-id"
}

data "aws_ssm_parameter" "resizing_img_func_name" {
  name = "${local.parameter_prefix}/resizing-img-func-name"
}

data "aws_ssm_parameter" "resizing_img_func_role" {
  name = "${local.parameter_prefix}/resizing-img-func-role"
}

data "aws_ssm_parameter" "resizing_img_func_handler" {
  name = "${local.parameter_prefix}/resizing-img-func-handler"
}

data "aws_ssm_parameter" "resizing_img_func_runtime" {
  name = "${local.parameter_prefix}/resizing-img-func-runtime"
}

data "aws_ssm_parameter" "resizing_img_func_layers" {
  name = "${local.parameter_prefix}/resizing-img-func-layers"
}

data "aws_ssm_parameter" "thumbnail_generating_func_name" {
  name = "${local.parameter_prefix}/thumbnail-generating-func-name"
}

data "aws_ssm_parameter" "thumbnail_generating_func_role" {
  name = "${local.parameter_prefix}/thumbnail-generating-func-role"
}

data "aws_ssm_parameter" "thumbnail_generating_func_handler" {
  name = "${local.parameter_prefix}/thumbnail-generating-func-handler"
}

data "aws_ssm_parameter" "thumbnail_generating_func_runtime" {
  name = "${local.parameter_prefix}/thumbnail-generating-func-runtime"
}

data "aws_ssm_parameter" "thumbnail_generating_func_layers" {
  name = "${local.parameter_prefix}/thumbnail-generating-func-layers"
}

locals {
  s3_upload_bucket_name             = data.aws_ssm_parameter.s3_upload_bucket_name.value
  upload_cdn_web_acl_id             = data.aws_ssm_parameter.upload_cdn_web_acl_id.value
  resizing_img_func_name            = data.aws_ssm_parameter.resizing_img_func_name.value
  resizing_img_func_role            = data.aws_ssm_parameter.resizing_img_func_role.value
  resizing_img_func_handler         = data.aws_ssm_parameter.resizing_img_func_handler.value
  resizing_img_func_runtime         = data.aws_ssm_parameter.resizing_img_func_runtime.value
  resizing_img_func_layers          = jsondecode(data.aws_ssm_parameter.resizing_img_func_layers.value)
  thumbnail_generating_func_name    = data.aws_ssm_parameter.thumbnail_generating_func_name.value
  thumbnail_generating_func_role    = data.aws_ssm_parameter.thumbnail_generating_func_role.value
  thumbnail_generating_func_handler = data.aws_ssm_parameter.thumbnail_generating_func_handler.value
  thumbnail_generating_func_runtime = data.aws_ssm_parameter.thumbnail_generating_func_runtime.value
  thumbnail_generating_func_layers  = jsondecode(data.aws_ssm_parameter.thumbnail_generating_func_layers.value)
}
