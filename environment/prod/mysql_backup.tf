resource "aws_s3_bucket" "mysql_backup" {
  bucket              = var.mysql_backup_bucket_name
  force_destroy       = false
  object_lock_enabled = true

  tags = {
    Name = var.mysql_backup_bucket_name
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "mysql_backup" {
  bucket = aws_s3_bucket.mysql_backup.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "mysql_backup" {
  bucket = aws_s3_bucket.mysql_backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "mysql_backup" {
  bucket = aws_s3_bucket.mysql_backup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.mysql_backup.arn,
          "${aws_s3_bucket.mysql_backup.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
    ]
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mysql_backup" {
  bucket = aws_s3_bucket.mysql_backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "mysql_backup" {
  bucket = aws_s3_bucket.mysql_backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "mysql_backup" {
  bucket = aws_s3_bucket.mysql_backup.id

  depends_on = [aws_s3_bucket_versioning.mysql_backup]

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = 14
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "mysql_backup" {
  bucket = aws_s3_bucket.mysql_backup.id

  depends_on = [
    aws_s3_bucket_versioning.mysql_backup,
    aws_s3_bucket_object_lock_configuration.mysql_backup,
  ]

  rule {
    id     = "expire-mysql-backups-after-14-days"
    status = "Enabled"

    filter {}

    expiration {
      days = 14
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  rule {
    id     = "remove-expired-delete-markers"
    status = "Enabled"

    filter {}

    expiration {
      expired_object_delete_marker = true
    }
  }
}

# S3 Gateway Endpoint에는 별도 시간당 또는 데이터 처리 비용이 없습니다.
# 접근 권한은 Terraform에 선언하지 않고 수동으로 관리하는 IAM 정책에서 제한합니다.
data "aws_route_table" "db_ec2" {
  subnet_id = var.db_ec2_subnet_id
}

resource "aws_vpc_endpoint" "mysql_backup_s3" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.ap-northeast-2.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_route_table.db_ec2.id]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowBackupBucketMetadataAccess"
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:ListBucketVersions",
        ]
        Resource = aws_s3_bucket.mysql_backup.arn
      },
      {
        Sid       = "AllowBackupObjectAccess"
        Effect    = "Allow"
        Principal = "*"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:ListMultipartUploadParts",
          "s3:PutObject",
        ]
        Resource = "${aws_s3_bucket.mysql_backup.arn}/*"
      },
    ]
  })

  tags = {
    Name = "solid-connection-prod-mysql-backup-s3"
  }
}
