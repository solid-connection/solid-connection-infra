# 1. CDN for Default Bucket
resource "aws_cloudfront_distribution" "default_cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "solid-connection s3 default cloudfront"
  price_class         = "PriceClass_All"
  http_version        = "http2"

  web_acl_id          = var.default_cdn_web_acl_id

  tags = {
    "Name" = "solid-connection s3 default cloudfront"
  }

  origin {
    domain_name              = "${var.s3_default_bucket_name}.s3.ap-northeast-2.amazonaws.com"
    origin_id                = "${var.s3_default_bucket_name}.s3.ap-northeast-2.amazonaws.com-mjo1g7tk2w8" # 기존 ID 유지
    origin_access_control_id = "E14M8OP55A3YO7"

    connection_attempts      = 3
    connection_timeout       = 10
  }

  default_cache_behavior {
    target_origin_id       = "${var.s3_default_bucket_name}.s3.ap-northeast-2.amazonaws.com-mjo1g7tk2w8" # 위 origin_id와 같아야 함
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]

    cache_policy_id  = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    smooth_streaming = false
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
      locations        = []
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1"
  }
}

# 2. CDN for Upload Bucket
resource "aws_cloudfront_distribution" "upload_cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "solid-connection s3 upload cloudfront"
  price_class         = "PriceClass_All"
  http_version        = "http2"

  web_acl_id          = var.upload_cdn_web_acl_id

  tags = {
    "Name" = "solid-connection s3 upload cloudfront"
  }

  origin {
    domain_name              = "${var.s3_upload_bucket_name}.s3.ap-northeast-2.amazonaws.com"
    origin_id                = "${var.s3_upload_bucket_name}.s3.ap-northeast-2.amazonaws.com-mjo1jpx6rvc"
    origin_access_control_id = "E1ZBB5RMSBZQ4I"

    connection_attempts      = 3
    connection_timeout       = 10
  }

  default_cache_behavior {
    target_origin_id       = "${var.s3_upload_bucket_name}.s3.ap-northeast-2.amazonaws.com-mjo1jpx6rvc"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]

    cache_policy_id  = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    smooth_streaming = false
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
      locations        = []
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1"
  }
}