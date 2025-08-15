# aoss.tf

data "aws_caller_identity" "current" {}

variable "project" {
  type    = string
  default = "ai-kb"
}

variable "env" {
  type    = string
  default = "dev"
}

variable "region" {
  type    = string
  default = "ap-southeast-2"
}

locals {
  name            = "${var.project}-${var.env}"
  collection_name = "${local.name}-kb"
}

# --- Encryption policy MUST exist before the collection ---
resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${local.name}-enc"
  type = "encryption"

  policy = jsonencode({
    Rules = [
      {
        ResourceType = "collection",
        # Reference the literal name, not a resource attribute
        Resource     = ["collection/${local.collection_name}"]
      }
    ],
    AWSOwnedKey = true
  })
}

# --- Network policy (public for dev; tighten later) ---
resource "aws_opensearchserverless_security_policy" "network" {
  name = "${local.name}-net"
  type = "network"

  policy = jsonencode({
    Rules = [
      {
        ResourceType = "collection",
        Resource     = ["collection/${local.collection_name}"]
      },
      {
        ResourceType = "dashboard",
        Resource     = ["collection/${local.collection_name}"]
      }
    ],
    AllowFromPublic = true
  })
}

# --- Collection (create AFTER policies) ---
resource "aws_opensearchserverless_collection" "kb" {
  name = local.collection_name
  type = "VECTORSEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network
  ]
}

# --- Data access policy: allow your Lambda roles ---
# If you created the lambdas as resources named aws_lambda_function.ingest/query:
resource "aws_opensearchserverless_access_policy" "data" {
  name = "${local.name}-data"
  type = "data"

  policy = jsonencode([
    {
      Description = "Lambda access for ingest + query",
      Rules = [
        {
          Resource   = ["collection/${local.collection_name}"],
          Permission = ["aoss:DescribeCollectionItems"]
        },
        {
          Resource   = ["index/${local.collection_name}/*"],
          Permission = [
            "aoss:CreateIndex",
            "aoss:DeleteIndex",
            "aoss:UpdateIndex",
            "aoss:DescribeIndex",
            "aoss:ReadDocument",
            "aoss:WriteDocument"
          ]
        }
      ],
      # Use the LAMBDA ROLE ARNs (not function ARNs)
      Principal = [
        aws_lambda_function.ingest.role,
        aws_lambda_function.query.role
      ]
    }
  ])

  depends_on = [aws_opensearchserverless_collection.kb]
}

output "aoss_endpoint" {
  description = "Collection endpoint URL"
  value       = aws_opensearchserverless_collection.kb.collection_endpoint
}

output "aoss_dashboard" {
  description = "Dashboards URL"
  value       = aws_opensearchserverless_collection.kb.dashboard_endpoint
}
