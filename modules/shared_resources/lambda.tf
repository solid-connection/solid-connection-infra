# 1. Lambda 소스 코드 압축
data "archive_file" "resizing_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src/img_resizing"
  output_path = "${path.module}/dist/img_resizing.zip"
}

data "archive_file" "thumbnail_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src/thumbnail"
  output_path = "${path.module}/dist/thumbnail.zip"
}

# 2. Lambda Resource Definition
resource "aws_lambda_function" "resizing_img_func" {
  function_name = var.resizing_img_func_name
  role          = var.resizing_img_func_role
  handler       = var.resizing_img_func_handler
  runtime       = var.resizing_img_func_runtime

  filename      = data.archive_file.resizing_zip.output_path
  source_code_hash = data.archive_file.resizing_zip.output_base64sha256

  layers        = var.resizing_img_func_layers
  timeout       = 15
}

resource "aws_lambda_function" "thumbnail_generating_func" {
  function_name = var.thumbnail_generating_func_name
  role          = var.thumbnail_generating_func_role
  handler       = var.thumbnail_generating_func_handler
  runtime       = var.thumbnail_generating_func_runtime

  filename         = data.archive_file.thumbnail_zip.output_path
  source_code_hash = data.archive_file.thumbnail_zip.output_base64sha256

  layers        = var.thumbnail_generating_func_layers
  timeout       = 15
}

# 3. Lambda Privileges Definition
resource "aws_lambda_permission" "allow_s3_resizing" {
  statement_id  = "AllowExecutionFromS3Bucket-Resizing"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.resizing_img_func.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.default.arn
}

resource "aws_lambda_permission" "allow_s3_thumbnail" {
  statement_id  = "AllowExecutionFromS3Bucket-Thumbnail"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.thumbnail_generating_func.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.default.arn
}

# 4. S3 Trigger Setting
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.default.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.resizing_img_func.arn
    events              = ["s3:ObjectCreated:Put", "s3:ObjectCreated:Post"]
    filter_prefix       = "original/"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.thumbnail_generating_func.arn
    events              = ["s3:ObjectCreated:Put"]
    filter_prefix       = "chat/images/"
  }

  depends_on = [
    aws_lambda_permission.allow_s3_resizing,
    aws_lambda_permission.allow_s3_thumbnail
  ]
}