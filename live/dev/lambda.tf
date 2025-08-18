locals {
  name = "ai-kb-dev"
}

# ----------------------------
# Shared policy: AOSS API access for Lambdas
# ----------------------------
data "aws_iam_policy_document" "aoss_api_access" {
  statement {
    sid     = "AllowAOSSDataPlane"
    effect  = "Allow"
    actions = ["aoss:APIAccessAll"]
    resources = ["*"] # scope later to collection ARN if you prefer
  }
}

resource "aws_iam_policy" "aoss_api_access" {
  name   = "aoss-api-access"
  policy = data.aws_iam_policy_document.aoss_api_access.json
}

# ----------------------------
# Ingest Lambda: role + perms
# ----------------------------
resource "aws_iam_role" "ingest_exec" {
  name = "${local.name}-ingest-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Action    = "sts:AssumeRole",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ingest_logs" {
  role       = aws_iam_role.ingest_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Minimal inline policy: S3 read (correct resources)
resource "aws_iam_role_policy" "ingest_runtime_s3" {
  name = "${local.name}-ingest-runtime-s3"
  role = aws_iam_role.ingest_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["s3:ListBucket"],
        Resource = "${aws_s3_bucket.rag-documents_bucket.arn}"
      },
      {
        Effect   = "Allow",
        Action   = ["s3:GetObject"],
        Resource = "${aws_s3_bucket.rag-documents_bucket.arn}/*"
      }
    ]
  })
}

# Attach AOSS API access to ingest role
resource "aws_iam_role_policy_attachment" "ingest_aoss" {
  role       = aws_iam_role.ingest_exec.name
  policy_arn = aws_iam_policy.aoss_api_access.arn
}

# ---- Package the ingest lambda
data "archive_file" "ingest_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/ingest"  # contains app.py
  output_path = "${path.module}/zips/ingest.zip"
}

resource "aws_lambda_function" "ingest" {
  function_name    = "${local.name}-ingest"
  role             = aws_iam_role.ingest_exec.arn
  runtime          = "python3.12"
  handler          = "app.handler"

  filename         = data.archive_file.ingest_zip.output_path
  source_code_hash = data.archive_file.ingest_zip.output_base64sha256

  timeout     = 60
  memory_size = 512

  environment {
    variables = {
      OPENSEARCH_ENDPOINT = aws_opensearchserverless_collection.kb.collection_endpoint
      INDEX_NAME          = "chunks"
      EMBED_DIM           = "1024"
      SKIP_AOSS           = "0"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.ingest_logs,
    aws_iam_role_policy_attachment.ingest_aoss,
    aws_iam_role_policy.ingest_runtime_s3
  ]
}

# S3 -> Lambda trigger
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
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke]
}

# ----------------------------
# Query Lambda: role + perms
# ----------------------------
data "archive_file" "query_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/query" # contains app.py
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

# Bedrock invoke (keep broad for now; scope later)
resource "aws_iam_role_policy" "query_runtime_bedrock" {
  name = "${local.name}-query-runtime-bedrock"
  role = aws_iam_role.query_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        Resource = "*"
      }
    ]
  })
}

# Attach AOSS API access to query role
resource "aws_iam_role_policy_attachment" "query_aoss" {
  role       = aws_iam_role.query_exec.name
  policy_arn = aws_iam_policy.aoss_api_access.arn
}

resource "aws_lambda_function" "query" {
  function_name    = "${local.name}-query"
  role             = aws_iam_role.query_exec.arn
  runtime          = "python3.12"
  handler          = "app.handler"

  filename         = data.archive_file.query_zip.output_path
  source_code_hash = data.archive_file.query_zip.output_base64sha256

  timeout     = 30
  memory_size = 512

  environment {
    variables = {
      # AOSS
      OPENSEARCH_ENDPOINT = aws_opensearchserverless_collection.kb.collection_endpoint
      INDEX_NAME          = "chunks"

      # Bedrock (adjust as needed)
      BEDROCK_REGION = "us-west-2"
      EMBED_MODEL_ID = "amazon.titan-embed-text-v2:0"
      CHAT_MODEL_ID  = "anthropic.claude-3-sonnet-20240229-v1:0"

      EMBED_DIM = "1024"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.query_logs,
    aws_iam_role_policy_attachment.query_aoss,
    aws_iam_role_policy.query_runtime_bedrock,
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
