# 8. S3 Buckets
resource "aws_s3_bucket" "default" {
  bucket = var.s3_default_bucket_name

  force_destroy = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags_all]
  }
}

resource "aws_s3_bucket" "upload" {
  bucket = var.s3_upload_bucket_name

  force_destroy = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags_all]
  }
}
