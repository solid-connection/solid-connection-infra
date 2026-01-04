resource "aws_acm_certificate" "default_cdn_cert" {
  provider          = aws.virginia
  domain_name       = "cdn.default.solid-connection.com"
  validation_method = "DNS"

  tags = {
    Name = "cdn-default-solid-connection-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "upload_cdn_cert" {
  provider          = aws.virginia
  domain_name       = "cdn.upload.solid-connection.com"
  validation_method = "DNS"

  tags = {
    Name = "cdn-upload-solid-connection-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}