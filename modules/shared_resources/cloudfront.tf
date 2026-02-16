# 0. S3 bucket Information read (Data Source)
data "aws_s3_bucket" "default" {
  bucket = var.s3_default_bucket_name
}

data "aws_s3_bucket" "upload" {
  bucket = var.s3_upload_bucket_name
}

# 1. OAC (Origin Access Control) 리소스 정의
# 하드코딩된 ID 대신, 테라폼 리소스로 관리하여 ID를 동적으로 참조합니다.
resource "aws_cloudfront_origin_access_control" "default_oac" {
  name                              = "default-oac-${var.s3_default_bucket_name}"
  description                       = "OAC for Default Bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_origin_access_control" "upload_oac" {
  name                              = "upload-oac-${var.s3_upload_bucket_name}"
  description                       = "OAC for Upload Bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# 2. CDN for Default Bucket
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

  aliases = [aws_acm_certificate.default_cdn_cert.domain_name]

  origin {
    domain_name              = data.aws_s3_bucket.default.bucket_regional_domain_name
    origin_id                = "S3-${var.s3_default_bucket_name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.default_oac.id

    connection_attempts      = 3
    connection_timeout       = 10
  }

  default_cache_behavior {
    target_origin_id       = "S3-${var.s3_default_bucket_name}" # 위 origin_id와 같아야 함
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
    acm_certificate_arn            = aws_acm_certificate.default_cdn_cert.arn
    minimum_protocol_version       = "TLSv1.2_2021"
    ssl_support_method             = "sni-only"
  }
}

# 3. CDN for Upload Bucket
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