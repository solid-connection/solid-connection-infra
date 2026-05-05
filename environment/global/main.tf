module "shared_resources" {
  source = "../../modules/shared_resources"

  providers = {
    aws = aws
  }

  s3_upload_bucket_name = local.s3_upload_bucket_name

  resizing_img_func_name    = local.resizing_img_func_name
  resizing_img_func_role    = local.resizing_img_func_role
  resizing_img_func_handler = local.resizing_img_func_handler
  resizing_img_func_runtime = local.resizing_img_func_runtime
  resizing_img_func_layers  = local.resizing_img_func_layers

  thumbnail_generating_func_name    = local.thumbnail_generating_func_name
  thumbnail_generating_func_role    = local.thumbnail_generating_func_role
  thumbnail_generating_func_handler = local.thumbnail_generating_func_handler
  thumbnail_generating_func_runtime = local.thumbnail_generating_func_runtime
  thumbnail_generating_func_layers  = local.thumbnail_generating_func_layers

  upload_cdn_web_acl_id = local.upload_cdn_web_acl_id
}
