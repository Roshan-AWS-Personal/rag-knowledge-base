locals {
  name = "ai-kb-dev"
}

# ---- IAM role for ingest lambda ----
resource "aws_iam_role" "ingest_exec" {
  name = "${local.name}-ingest-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = "sts:AssumeRole",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy_attachment" "ingest_logs" {
  name       = "${local.name}-ingest-logs"
  roles      = [aws_iam_role.ingest_exec.name]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Minimal inline policy: S3 read + AOSS API (dev-friendly; tighten later)
resource "aws_iam_role_policy" "ingest_runtime" {
  name = "${local.name}-ingest-runtime"
  role = aws_iam_role.ingest_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect: "Allow",
        Action: ["s3:GetObject", "s3:ListBucket"],
        Resource: [
          "${aws_s3_bucket.rag-documents_bucket.arn}/*"
        ]
      },
      {
        Effect: "Allow",
        Action: ["aoss:APIAccessAll"],
        Resource: "*"
      }
    ]
  })
}

# ---- Package the lambda from a folder (like before) ----
data "archive_file" "ingest_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/ingest"  # <- must contain app.py
  output_path = "${path.module}/zips/ingest.zip"
}

resource "aws_lambda_function" "ingest" {
  function_name    = "${local.name}-ingest"
  role             = aws_iam_role.ingest_exec.arn
  runtime          = "python3.12"
  handler          = "app.handler"

  filename         = data.archive_file.ingest_zip.output_path
  source_code_hash = data.archive_file.ingest_zip.output_base64sha256

  timeout          = 60
  memory_size      = 512

  environment {
    variables = {
      OPENSEARCH_ENDPOINT = aws_opensearchserverless_collection.kb.collection_endpoint
      INDEX_NAME          = "chunks"
      EMBED_DIM           = "1024"
      # we’ll add BEDROCK_REGION/EMBED_MODEL_ID later when we embed
    }
  }
}

# ---- Direct S3 -> Lambda trigger (like your previous) ----
resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowS3InvokeDocs"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.rag-documents_bucket.arn
}

resource "aws_s3_bucket_notification" "docs_trigger_ingest" {
  bucket = aws_s3_bucket.rag-documents_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.ingest.arn
    events              = ["s3:ObjectCreated:*"]
    # optional filters:
    # filter_prefix = "incoming/"
    # filter_suffix = ".txt"
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke]
}
