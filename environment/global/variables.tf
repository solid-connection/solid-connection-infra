# [S3 버킷 관련 변수]
variable "s3_default_bucket_name" {
  description = "Name of the default S3 bucket"
  type        = string
}

variable "s3_upload_bucket_name" {
  description = "Name of the upload S3 bucket"
  type        = string
}

# [Lambda 관련 변수]
variable "resizing_img_func_name" {
  description = "Image Resizing function name for uploaded s3 file"
  type = string
}

variable "resizing_img_func_role" {
  description = "Image Resizing function role for uploaded s3 file"
  type = string
}

variable "resizing_img_func_handler" {
  description = "Image Resizing function handler for uploaded s3 file"
  type = string
}

variable "resizing_img_func_runtime" {
  description = "Image Resizing function runtime for uploaded s3 file"
  type = string
}

variable "thumbnail_generating_func_name" {
  description = "Thumbnail generating function name for uploaded s3 file"
  type = string
}

variable "thumbnail_generating_func_role" {
  description = "Thumbnail generating function role for uploaded s3 file"
  type = string
}

variable "thumbnail_generating_func_handler" {
  description = "Thumbnail generating function handler for uploaded s3 file"
  type = string
}

variable "thumbnail_generating_func_runtime" {
  description = "Thumbnail generating function runtime for uploaded s3 file"
  type = string
}

variable "resizing_img_func_layers" {
  description = "Layers For Image Resizing func"
  type = list(string)
}

variable "thumbnail_generating_func_layers" {
  description = "Layers For Image Resizing func"
  type = list(string)
}

variable "default_cdn_web_acl_id" {
  description = "WAF Web ACL Id for Default Cloudfront CDN"
  type = string
}

variable "upload_cdn_web_acl_id" {
  description = "WAF Web ACL Id for Upload Cloudfront CDN"
  type = string
}
