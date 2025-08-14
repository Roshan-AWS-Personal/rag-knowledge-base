# lambda-build.tf
locals {
  name            = "${var.project}-${var.env}"
  ingest_abs_src  = abspath("${path.module}/${var.ingest_src_dir}")
  query_abs_src   = abspath("${path.module}/${var.query_src_dir}")

  ingest_files    = fileset(local.ingest_abs_src, "**")
  query_files     = fileset(local.query_abs_src,  "**")

  ingest_hash     = sha256(join("", [for f in local.ingest_files : filesha256("${local.ingest_abs_src}/${f}")]))
  query_hash      = sha256(join("", [for f in local.query_files  : filesha256("${local.query_abs_src}/${f}")]))

  ingest_build    = "${path.module}/.build/ingest"
  query_build     = "${path.module}/.build/query"
}

# Build step: vendor requirements.txt (if any) + copy sources
resource "null_resource" "build_ingest" {
  triggers = { src_hash = local.ingest_hash }

  provisioner "local-exec" {
    command = <<-EOC
      set -e
      rm -rf "${local.ingest_build}"
      mkdir -p "${local.ingest_build}"
      if [ -f "${local.ingest_abs_src}/requirements.txt" ]; then
        python -m pip install -r "${local.ingest_abs_src}/requirements.txt" -t "${local.ingest_build}"
      fi
      rsync -a --exclude __pycache__/ --exclude "*.pyc" "${local.ingest_abs_src}/" "${local.ingest_build}/"
    EOC
    interpreter = ["/bin/bash", "-c"]
  }
}

resource "null_resource" "build_query" {
  triggers = { src_hash = local.query_hash }

  provisioner "local-exec" {
    command = <<-EOC
      set -e
      rm -rf "${local.query_build}"
      mkdir -p "${local.query_build}"
      if [ -f "${local.query_abs_src}/requirements.txt" ]; then
        python -m pip install -r "${local.query_abs_src}/requirements.txt" -t "${local.query_build}"
      fi
      rsync -a --exclude __pycache__/ --exclude "*.pyc" "${local.query_abs_src}/" "${local.query_build}/"
    EOC
    interpreter = ["/bin/bash", "-c"]
  }
}

# Zip them
data "archive_file" "ingest_zip" {
  type        = "zip"
  source_dir  = local.ingest_build
  output_path = "${path.module}/.build/ingest.zip"
  depends_on  = [null_resource.build_ingest]
}

data "archive_file" "query_zip" {
  type        = "zip"
  source_dir  = local.query_build
  output_path = "${path.module}/.build/query.zip"
  depends_on  = [null_resource.build_query]
}

# lambda-iam.tf
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals { 
    type = "Service"
    identifiers = ["lambda.amazonaws.com"] 
    }
  }
}

resource "aws_iam_role" "ingest_exec" {
  name               = "${local.name}-ingest-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = { Project = var.project, Env = var.env }
}

resource "aws_iam_role" "query_exec" {
  name               = "${local.name}-query-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = { Project = var.project, Env = var.env }
}

# Basic logs
resource "aws_iam_role_policy_attachment" "ingest_logs" {
  role       = aws_iam_role.ingest_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy_attachment" "query_logs" {
  role       = aws_iam_role.query_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Custom permissions (dev-friendly; tighten later)
data "aws_iam_policy_document" "ingest_perms" {
  statement { # read docs from S3
    effect = "Allow"
    actions = ["s3:GetObject","s3:ListBucket"]
    resources = [
      "${aws_s3_bucket.rag-documents_bucket.arn}/*",
    ]
  }
  statement { # Bedrock embeddings
    effect = "Allow"
    actions = ["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"]
    resources = ["*"] # scope to model ARNs later
  }
  statement { # OpenSearch Serverless API access
    effect = "Allow"
    actions = ["aoss:APIAccessAll"]
    resources = ["*"] # scope to your collection ARN later
  }
}

data "aws_iam_policy_document" "query_perms" {
  statement { # Bedrock chat
    effect = "Allow"
    actions = ["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"]
    resources = ["*"]
  }
  statement { # OpenSearch Serverless query
    effect = "Allow"
    actions = ["aoss:APIAccessAll"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ingest_policy" {
  name   = "${local.name}-ingest-perms"
  policy = data.aws_iam_policy_document.ingest_perms.json
}
resource "aws_iam_policy" "query_policy" {
  name   = "${local.name}-query-perms"
  policy = data.aws_iam_policy_document.query_perms.json
}
resource "aws_iam_role_policy_attachment" "ingest_policy_attach" {
  role       = aws_iam_role.ingest_exec.name
  policy_arn = aws_iam_policy.ingest_policy.arn
}
resource "aws_iam_role_policy_attachment" "query_policy_attach" {
  role       = aws_iam_role.query_exec.name
  policy_arn = aws_iam_policy.query_policy.arn
}

# lambdas.tf
resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${local.name}-ingest"
  retention_in_days = 14
}
resource "aws_cloudwatch_log_group" "query" {
  name              = "/aws/lambda/${local.name}-query"
  retention_in_days = 14
}

resource "aws_lambda_function" "ingest" {
  function_name    = "${local.name}-ingest"
  role             = aws_iam_role.ingest_exec.arn
  runtime          = var.lambda_runtime
  handler          = "app.handler"
  filename         = data.archive_file.ingest_zip.output_path
  source_code_hash = data.archive_file.ingest_zip.output_base64sha256
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_mb

  environment {
    variables = {
      BEDROCK_REGION     = var.bedrock_region
      EMBED_MODEL_ID     = var.embed_model_id
      INDEX_NAME         = var.index_name
      OPENSEARCH_ENDPOINT= aws_opensearchserverless_collection.kb.collection_endpoint
      EMBED_DIM          = tostring(var.embed_dim)
    }
  }

  depends_on = [aws_cloudwatch_log_group.ingest]
}

resource "aws_lambda_function" "query" {
  function_name    = "${local.name}-query"
  role             = aws_iam_role.query_exec.arn
  runtime          = var.lambda_runtime
  handler          = "app.handler"
  filename         = data.archive_file.query_zip.output_path
  source_code_hash = data.archive_file.query_zip.output_base64sha256
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_mb

  environment {
    variables = {
      BEDROCK_REGION     = var.bedrock_region
      CHAT_MODEL_ID      = var.chat_model_id
      INDEX_NAME         = var.index_name
      OPENSEARCH_ENDPOINT= aws_opensearchserverless_collection.kb.collection_endpoint
    }
  }

  depends_on = [aws_cloudwatch_log_group.query]
}

