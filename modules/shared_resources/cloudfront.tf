# 0. S3 bucket Information read (Data Source)
data "aws_s3_bucket" "upload" {
  bucket = var.s3_upload_bucket_name
}

# 1. OAC (Origin Access Control) 리소스 정의
resource "aws_cloudfront_origin_access_control" "upload_oac" {
  name                              = "upload-oac-${var.s3_upload_bucket_name}"
  description                       = "OAC for Upload Bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
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

  aliases = [aws_acm_certificate.upload_cdn_cert.domain_name]

  origin {
    domain_name              = data.aws_s3_bucket.upload.bucket_regional_domain_name
    origin_id                = "S3-${var.s3_upload_bucket_name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.upload_oac.id

    connection_attempts      = 3
    connection_timeout       = 10
  }

  default_cache_behavior {
    target_origin_id       = "S3-${var.s3_upload_bucket_name}"
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
    cloudfront_default_certificate = false
    acm_certificate_arn            = aws_acm_certificate.upload_cdn_cert.arn
    minimum_protocol_version       = "TLSv1.2_2021"
    ssl_support_method             = "sni-only"
  }
}