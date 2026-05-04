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