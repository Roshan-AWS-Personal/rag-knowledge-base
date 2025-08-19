locals {
  name = "ai-kb-dev"
}

# ----------------------------
# AOSS (OpenSearch Serverless) API access (broad for now; scope later)
# ----------------------------
data "aws_iam_policy_document" "aoss_api_access" {
  statement {
    sid     = "AllowAOSSDataPlane"
    effect  = "Allow"
    actions = ["aoss:APIAccessAll"]
    resources = ["*"] # TODO: restrict to collection ARN(s)
  }
}

resource "aws_iam_policy" "aoss_api_access" {
  name   = "${local.name}-aoss-api-access"
  policy = data.aws_iam_policy_document.aoss_api_access.json
}

# ============================================================
# INGEST LAMBDA — reads from S3, writes to AOSS
# Directory layout expected:
#   ./lambda/ingest/lambda_function.py  (and any deps)
# ============================================================

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

resource "aws_iam_role_policy_attachment" "ingest_logs" {
  role       = aws_iam_role.ingest_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Minimal runtime policy: S3 read + AOSS API
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
          "arn:aws:s3:::${local.name}-data",
          "arn:aws:s3:::${local.name}-data/*"
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

# Build ZIP at apply time
data "archive_file" "ingest_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/ingest"
  output_path = "${path.module}/build/ingest.zip"
}

resource "aws_lambda_function" "ingest" {
  function_name    = "${local.name}-ingest"
  role             = aws_iam_role.ingest_exec.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  filename         = data.archive_file.ingest_zip.output_path
  source_code_hash = data.archive_file.ingest_zip.output_base64sha256
  timeout          = 60
  publish          = true
}

# ============================================================
# QUERY LAMBDA — reads from AOSS
# Directory layout expected:
#   ./lambda/query/lambda_function.py  (and any deps)
# ============================================================

resource "aws_iam_role" "query_exec" {
  name = "${local.name}-query-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = "sts:AssumeRole",
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
        Effect: "Allow",
        Action: ["aoss:APIAccessAll"],
        Resource: "*"
      }
    ]
  })
}

# Build ZIP at apply time
data "archive_file" "query_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/query"
  output_path = "${path.module}/build/query.zip"
}

resource "aws_lambda_function" "query" {
  function_name    = "${local.name}-query"
  role             = aws_iam_role.query_exec.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  filename         = data.archive_file.query_zip.output_path
  source_code_hash = data.archive_file.query_zip.output_base64sha256
  timeout          = 60
  publish          = true
}