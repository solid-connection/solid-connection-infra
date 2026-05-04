output "acm_validation_records" {
  description = "Cloudflare에 등록해야 할 인증서 검증용 CNAME 값들 (Proxy Off 필수!)"
  value = {
    upload_cdn = {
      for dvo in aws_acm_certificate.upload_cdn_cert.domain_validation_options : dvo.domain_name => {
        name   = dvo.resource_record_name
        record = dvo.resource_record_value
      }
    }
  }
}