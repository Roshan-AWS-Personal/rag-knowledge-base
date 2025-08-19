locals {
  name = "ai-kb-dev"
}

# ----------------------------
# Shared inline policy: AOSS API access
# ----------------------------
data "aws_iam_policy_document" "aoss_api_access" {
  statement {
    sid     = "AllowAOSSDataPlane"
    effect  = "Allow"
    actions = [
      "aoss:APIAccessAll"
    ]
    resources = ["*"] # TODO: restrict to collection ARN later
  }
}

resource "aws_iam_policy" "aoss_api_access" {
  name   = "${local.name}-aoss-api-access"
  policy = data.aws_iam_policy_document.aoss_api_access.json
}

# ============================================================
# INGEST LAMBDA
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

# S3 + AOSS access
resource "aws_iam_role_policy" "ingest_runtime" {
  name = "${local.name}-ingest-runtime"
  role = aws_iam_role.ingest_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Resource = [
          "arn:aws:s3:::${local.name}-data",
          "arn:aws:s3:::${local.name}-data/*"
        ]
      },
      {
        Effect   = "Allow",
        Action   = ["aoss:APIAccessAll"],
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "ingest" {
  function_name = "${local.name}-ingest"
  role          = aws_iam_role.ingest_exec.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.11"
  filename      = "${path.module}/lambdas/ingest.zip"
  timeout       = 60
}

# ============================================================
# QUERY LAMBDA
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

# Query Lambda only needs AOSS read
resource "aws_iam_role_policy" "query_runtime" {
  name = "${local.name}-query-runtime"
  role = aws_iam_role.query_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["aoss:APIAccessAll"],
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "query" {
  function_name = "${local.name}-query"
  role          = aws_iam_role.query_exec.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.11"
  filename      = "${path.module}/lambdas/query.zip"
  timeout       = 60
}
