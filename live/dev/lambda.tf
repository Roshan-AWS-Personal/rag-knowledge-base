############################################
# Locals & lookups
############################################
locals {
  name = "ai-kb-dev"
}

data "aws_region" "current" {}
data "aws_caller_identity" "me" {}

############################################
# ECR repositories (one per lambda)
############################################
resource "aws_ecr_repository" "ingest_repo" {
  name                 = "${local.name}-ingest"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
  force_delete = true
}

resource "aws_ecr_repository" "query_repo" {
  name                 = "${local.name}-query"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
  force_delete = true
}

############################################
# Build & push images with Terraform
############################################
# INGEST
resource "docker_image" "ingest" {
  name = "${aws_ecr_repository.ingest_repo.repository_url}:latest"

  build {
    context    = "${path.module}/lambda/ingest"
    dockerfile = "Dockerfile"
    # platform = "linux/amd64"  # uncomment if needed
  }

  keep_locally = true
}

resource "docker_registry_image" "ingest" {
  name          = docker_image.ingest.name
  keep_remotely = true
}

# QUERY
resource "docker_image" "query" {
  name = "${aws_ecr_repository.query_repo.repository_url}:latest"

  build {
    context    = "${path.module}/lambda/query"
    dockerfile = "Dockerfile"
    # platform = "linux/amd64"
  }

  keep_locally = true
}

resource "docker_registry_image" "query" {
  name          = docker_image.query.name
  keep_remotely = true
}

############################################
# IAM: Ingest Lambda
############################################
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

resource "aws_iam_role_policy" "ingest_runtime" {
  name = "${local.name}-ingest-runtime"
  role = aws_iam_role.ingest_exec.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid      = "DocsReadList",
        Effect   = "Allow",
        Action   = ["s3:ListBucket"],
        Resource = [aws_s3_bucket.rag-documents_bucket.arn],
        Condition = { StringLike = { "s3:prefix" = ["docs/*", "docs/"] } }
      },
      {
        Sid      = "DocsReadObjects",
        Effect   = "Allow",
        Action   = ["s3:GetObject"],
        Resource = ["${aws_s3_bucket.rag_documents_bucket.arn}/docs/*"]
      },
      {
        Sid      = "IndexWrite",
        Effect   = "Allow",
        Action   = ["s3:PutObject", "s3:DeleteObject", "s3:GetObject", "s3:HeadObject"],
        Resource = ["${aws_s3_bucket.rag_documents_bucket.arn}/indexes/*"]
      },
      {
        Sid      = "BedrockInvoke",
        Effect   = "Allow",
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        Resource = "*"
      }
    ]
  })
}

############################################
# IAM: Query Lambda
############################################
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
        Sid      = "IndexRead",
        Effect   = "Allow",
        Action   = ["s3:GetObject", "s3:HeadObject"],
        Resource = ["${aws_s3_bucket.rag_documents_bucket.arn}/indexes/*"]
      },
      {
        Sid      = "BedrockInvoke",
        Effect   = "Allow",
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        Resource = "*"
      }
    ]
  })
}

############################################
# Lambda (container images) – no OpenSearch
############################################
# We reference the **digest** so any image rebuild triggers an update automatically.
# image_uri format: <repo-url>@<sha256-digest>

resource "aws_lambda_function" "ingest" {
  function_name = "${local.name}-ingest"
  role          = aws_iam_role.ingest_exec.arn
  package_type  = "Image"

  # Digest from pushed image
  image_uri     = "${aws_ecr_repository.ingest_repo.repository_url}@${docker_registry_image.ingest.sha256_digest}"

  timeout       = 300
  memory_size   = 1024
  architectures = ["x86_64"]

  environment {
    variables = {
      S3_BUCKET      = aws_s3_bucket.rag_documents_bucket.bucket
      DOCS_PREFIX    = "docs/"
      INDEX_PREFIX   = "indexes/latest/"
      BEDROCK_REGION = data.aws_region.current.name
      EMBED_MODEL_ID = "amazon.titan-embed-text-v2:0"
      EMBED_DIM      = "1024"
    }
  }

  depends_on = [docker_registry_image.ingest]
}

resource "aws_lambda_function" "query" {
  function_name = "${local.name}-query"
  role          = aws_iam_role.query_exec.arn
  package_type  = "Image"

  image_uri     = "${aws_ecr_repository.query_repo.repository_url}@${docker_registry_image.query.sha256_digest}"

  timeout       = 60
  memory_size   = 2048
  architectures = ["x86_64"]

  ephemeral_storage { size = 4096 } # room for FAISS files in /tmp

  environment {
    variables = {
      S3_BUCKET      = aws_s3_bucket.rag_documents_bucket.bucket
      INDEX_PREFIX   = "indexes/latest/"
      BEDROCK_REGION = data.aws_region.current.name
      EMBED_MODEL_ID = "amazon.titan-embed-text-v2:0"
      EMBED_DIM      = "1024"
      TOP_K          = "5"
    }
  }

  depends_on = [docker_registry_image.query]
}

# Quick public URL (for dev). Secure with IAM/JWT later.
resource "aws_lambda_function_url" "query_url" {
  function_name      = aws_lambda_function.query.arn
  authorization_type = "NONE"
  cors {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["*"]
  }
}

############################################
# Outputs
############################################
output "ingest_repo_url" {
  value       = aws_ecr_repository.ingest_repo.repository_url
  description = "ECR repo for ingest image"
}

output "query_repo_url" {
  value       = aws_ecr_repository.query_repo.repository_url
  description = "ECR repo for query image"
}

output "query_function_url" {
  value       = aws_lambda_function_url.query_url.function_url
  description = "Public URL for query Lambda (dev)"
}
