module "shared_resources" {
  source = "../../modules/shared_resources"

  providers = {
    aws     = aws
  }

  s3_default_bucket_name            = var.s3_default_bucket_name
  s3_upload_bucket_name             = var.s3_upload_bucket_name

  resizing_img_func_name            = var.resizing_img_func_name
  resizing_img_func_role            = var.resizing_img_func_role
  resizing_img_func_handler         = var.resizing_img_func_handler
  resizing_img_func_runtime         = var.resizing_img_func_runtime
  resizing_img_func_layers          = var.resizing_img_func_layers

  thumbnail_generating_func_name    = var.thumbnail_generating_func_name
  thumbnail_generating_func_role    = var.thumbnail_generating_func_role
  thumbnail_generating_func_handler = var.thumbnail_generating_func_handler
  thumbnail_generating_func_runtime = var.thumbnail_generating_func_runtime
  thumbnail_generating_func_layers  = var.thumbnail_generating_func_layers

  default_cdn_web_acl_id            = var.default_cdn_web_acl_id
  upload_cdn_web_acl_id             = var.upload_cdn_web_acl_id
}