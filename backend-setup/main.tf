terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      # optional: pin a range you like
      # version = "~> 6.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      # optional: pin a range
      # version = "~> 3.0"
    }
  }
}

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

resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name
}

resource "aws_dynamodb_table" "tf_locks" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
