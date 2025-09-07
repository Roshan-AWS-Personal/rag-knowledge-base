############################################
# Locals & lookups
############################################
locals {
  name = "ai-kb-dev"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

############################################
# ECR repos (one per Lambda image)
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

# Change these when you push a new image tag so TF updates the Lambda
variable "ingest_image_tag" {
  type    = string
  default = "v1"
}
variable "query_image_tag" {
  type    = string
  default = "v1"
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

# S3: read docs, write indexes. Bedrock: embed calls.
resource "aws_iam_role_policy" "ingest_runtime" {
  name = "${local.name}-ingest-runtime"
  role = aws_iam_role.ingest_exec.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid      = "DocsReadList"
        Effect   = "Allow",
        Action   = ["s3:ListBucket"],
        Resource = [aws_s3_bucket.rag-documents_bucket.arn],
        Condition = {
          StringLike = {
            "s3:prefix" = ["docs/*", "docs/"]
          }
        }
      },
      {
        Sid      = "DocsReadObjects"
        Effect   = "Allow",
        Action   = ["s3:GetObject"],
        Resource = ["${aws_s3_bucket.rag-documents_bucket.arn}/docs/*"]
      },
      {
        Sid      = "IndexWrite"
        Effect   = "Allow",
        Action   = ["s3:PutObject", "s3:DeleteObject", "s3:GetObject", "s3:HeadObject"],
        Resource = ["${aws_s3_bucket.rag-documents_bucket.arn}/indexes/*"]
      },
      {
        Sid      = "BedrockInvoke"
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

# S3: read index artifacts. Bedrock: embed queries.
resource "aws_iam_role_policy" "query_runtime" {
  name = "${local.name}-query-runtime"
  role = aws_iam_role.query_exec.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid      = "IndexRead"
        Effect   = "Allow",
        Action   = ["s3:GetObject", "s3:HeadObject"],
        Resource = ["${aws_s3_bucket.rag-documents_bucket.arn}/indexes/*"]
      },
      {
        Sid      = "BedrockInvoke"
        Effect   = "Allow",
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        Resource = "*"
      }
    ]
  })
}

############################################
# Lambda (CONTAINER images) – no OpenSearch
############################################
# Ingest: build FAISS from docs -> upload index to S3
resource "aws_lambda_function" "ingest" {
  function_name = "${local.name}-ingest"
  role          = aws_iam_role.ingest_exec.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.ingest_repo.repository_url}:${var.ingest_image_tag}"

  timeout       = 300
  memory_size   = 1024
  architectures = ["x86_64"]

  environment {
    variables = {
      S3_BUCKET       = aws_s3_bucket.rag-documents_bucket.bucket
      DOCS_PREFIX     = "docs/"
      INDEX_PREFIX    = "indexes/latest/"
      BEDROCK_REGION  = data.aws_region.current.name
      EMBED_MODEL_ID  = "amazon.titan-embed-text-v2:0"
      EMBED_DIM       = "1024"
    }
  }
}

# Query: load FAISS from S3 (/tmp), answer queries
resource "aws_lambda_function" "query" {
  function_name = "${local.name}-query"
  role          = aws_iam_role.query_exec.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.query_repo.repository_url}:${var.query_image_tag}"

  timeout       = 60
  memory_size   = 2048
  architectures = ["x86_64"]

  # Space in /tmp for index files (adjust if needed)
  ephemeral_storage { size = 4096 }

  environment {
    variables = {
      S3_BUCKET       = aws_s3_bucket.rag-documents_bucket.bucket
      INDEX_PREFIX    = "indexes/latest/"
      BEDROCK_REGION  = data.aws_region.current.name
      EMBED_MODEL_ID  = "amazon.titan-embed-text-v2:0"
      EMBED_DIM       = "1024"
      TOP_K           = "5"
    }
  }
}

# Public URL for quick testing (optional; lock down in prod)
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
  description = "Push your ingest image here"
}

output "query_repo_url" {
  value       = aws_ecr_repository.query_repo.repository_url
  description = "Push your query image here"
}

output "query_function_url" {
  value       = aws_lambda_function_url.query_url.function_url
  description = "Public URL for query Lambda (dev)"
}
