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

# NEW (stable)
resource "aws_iam_role_policy_attachment" "ingest_logs" {
  role       = aws_iam_role.ingest_exec.name
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

############################################
# Query Lambda (packages from lambda/query)
############################################

# Zip the query lambda source folder (must contain app.py)
data "archive_file" "query_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/query"
  output_path = "${path.module}/zips/query.zip"
}

# Execution role
resource "aws_iam_role" "query_exec" {
  name = "${local.name}-query-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = "sts:AssumeRole",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Basic logging
resource "aws_iam_role_policy_attachment" "query_logs" {
  role       = aws_iam_role.query_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Runtime permissions (dev-friendly; tighten later)
resource "aws_iam_role_policy" "query_runtime" {
  name = "${local.name}-query-runtime"
  role = aws_iam_role.query_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        Resource = "*"
      },
      {
        Effect   = "Allow",
        Action   = ["aoss:APIAccessAll"],
        Resource = "*"
      }
    ]
  })
}

# Lambda function (uses environment vars to talk to AOSS + Bedrock)
resource "aws_lambda_function" "query" {
  function_name    = "${local.name}-query"
  role             = aws_iam_role.query_exec.arn
  runtime          = "python3.12"
  handler          = "app.handler"

  filename         = data.archive_file.query_zip.output_path
  source_code_hash = data.archive_file.query_zip.output_base64sha256

  timeout          = 30
  memory_size      = 512

  environment {
    variables = {
      # AOSS
      OPENSEARCH_ENDPOINT = aws_opensearchserverless_collection.kb.collection_endpoint
      INDEX_NAME          = "chunks"

      # Bedrock (adjust if you use different region/models)
      BEDROCK_REGION      = "us-west-2"
      EMBED_MODEL_ID      = "amazon.titan-embed-text-v2:0"
      CHAT_MODEL_ID       = "anthropic.claude-3-sonnet-20240229-v1:0"

      # Embedding dimension for index consistency
      EMBED_DIM           = "1024"
    }
  }

  # If your AOSS access policy references this role, it will already depend on it.
  # Keeping an explicit dependency on the collection helps with ordering.
  depends_on = [
    aws_opensearchserverless_collection.kb
  ]
}

# Helpful outputs
output "query_lambda_name" {
  value       = aws_lambda_function.query.function_name
  description = "Name of the query lambda"
}

output "query_lambda_arn" {
  value       = aws_lambda_function.query.arn
  description = "ARN of the query lambda"
}
