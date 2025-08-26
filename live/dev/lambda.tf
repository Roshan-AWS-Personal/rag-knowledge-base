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
    }
    ]
  })
}

# Logs
resource "aws_iam_role_policy_attachment" "ingest_logs" {
  role       = aws_iam_role.ingest_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Minimal inline policy: S3 read + AOSS API (SQS perms attached in sqs.tf)
resource "aws_iam_role_policy" "ingest_runtime" {
  name = "${local.name}-ingest-runtime"
  role = aws_iam_role.ingest_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["s3:GetObject", "s3:ListBucket"],
        Resource = [
          "${aws_s3_bucket.rag-documents_bucket.arn}",
          "${aws_s3_bucket.rag-documents_bucket.arn}/*"
        ]
      },
      {
        Effect   = "Allow",
        Action   = ["aoss:APIAccessAll"],
        Resource = "*"
      },
      {
        Effect   = "Allow",
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        Resource = "*"
      }
    ]
  })
}

# ---- Package the lambda from source folder ----
data "archive_file" "ingest_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/ingest"
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
      SKIP_AOSS           = "0" 
      BEDROCK_REGION      = "us-west-2"
      EMBED_MODEL_ID      = "amazon.titan-embed-text-v2:0"
      PREVIEW_KNN         = "1"   # set "0" to disable the quick preview logs
    }
  }

  depends_on = [aws_opensearchserverless_collection.kb]
}

############################################
# Query Lambda (unchanged)
############################################

data "archive_file" "query_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/query"
  output_path = "${path.module}/zips/query.zip"
}

resource "aws_iam_role" "query_exec" {
  name = "${local.name}-query-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Action    = "sts:AssumeRole",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "query_logs" {
  role       = aws_iam_role.query_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

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
      OPENSEARCH_ENDPOINT = aws_opensearchserverless_collection.kb.collection_endpoint
      INDEX_NAME          = "chunks"
      BEDROCK_REGION      = "ap-southeast-2"
      EMBED_MODEL_ID      = "amazon.titan-embed-text-v2:0"
      CHAT_MODEL_ID       = "anthropic.claude-3-sonnet-20240229-v1:0"
      EMBED_DIM           = "1024"
    }
  }

  depends_on = [aws_opensearchserverless_collection.kb]
}

output "query_lambda_name" {
  value       = aws_lambda_function.query.function_name
  description = "Name of the query lambda"
}

output "query_lambda_arn" {
  value       = aws_lambda_function.query.arn
  description = "ARN of the query lambda"
}
