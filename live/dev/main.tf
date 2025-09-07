terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      # optional: pin a range
      # version = "~> 3.0"
    }
  }
}

# If you set AWS region via env (AWS_REGION), you can omit this.
provider "aws" {}

# ---- Docker provider auth to ECR ----
data "aws_ecr_authorization_token" "ecr" {}

locals {
  # Docker Desktop must be running. On Windows, kreuzwerker/docker works with the npipe by default.
  ecr_address = replace(data.aws_ecr_authorization_token.ecr.proxy_endpoint, "https://", "")
}

provider "docker" {
  registry_auth {
    address  = local.ecr_address
    username = data.aws_ecr_authorization_token.ecr.user_name
    password = data.aws_ecr_authorization_token.ecr.password
  }
}


resource "aws_s3_bucket" "rag_documents_bucket" {
  bucket = "ai-kb-${var.env}-docs"
  force_destroy = true
}

data "aws_iam_policy_document" "s3_to_sqs" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.ingest_queue.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.rag-documents_bucket.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "allow_s3" {
  queue_url = aws_sqs_queue.ingest_queue.id
  policy    = data.aws_iam_policy_document.s3_to_sqs.json
}

# main.tf
resource "aws_s3_bucket_notification" "docs_to_sqs" {
  bucket = aws_s3_bucket.rag-documents_bucket.id

  queue {
    queue_arn = aws_sqs_queue.ingest_queue.arn
    events    = ["s3:ObjectCreated:*"]

    # Omit when empty (null means "don’t send the field")
    filter_prefix = var.s3_prefix != "" ? var.s3_prefix : null
    filter_suffix = var.s3_suffix != "" ? var.s3_suffix : null
  }

  # Ensure the queue policy exists before S3 registers the notification
  depends_on = [aws_sqs_queue_policy.allow_s3]
}

############################
# S3 static bucket (private; CF OAC only)
############################
resource "aws_s3_bucket" "site" {
  bucket = "${var.name}-site"
  tags = { Project = var.name }
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  restrict_public_buckets = true
  ignore_public_acls      = true
}

############################
# S3 bucket policy allowing CF OAC
############################
resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid: "AllowCloudFrontServicePrincipalReadOnly",
      Effect: "Allow",
      Principal: { Service: "cloudfront.amazonaws.com" },
      Action: ["s3:GetObject"],
      Resource: ["${aws_s3_bucket.site.arn}/*"],
      Condition: {
        StringEquals: {
          "AWS:SourceArn": aws_cloudfront_distribution.this.arn
        }
      }
    }]
  })
}

resource "aws_s3_object" "index_html" {
  bucket        = aws_s3_bucket.site.id
  key           = "index.html"
  content       = file("${path.module}/frontend/index.html")
  content_type  = "text/html"
  cache_control = "no-store, must-revalidate"
}

resource "aws_s3_bucket_cors_configuration" "website_cors" {
  bucket = aws_s3_bucket.site.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "GET"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

output "cloudfront_url" { value = "https://${aws_cloudfront_distribution.this.domain_name}" }
output "site_bucket"    { value = aws_s3_bucket.site.bucket }