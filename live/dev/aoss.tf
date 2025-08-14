locals {
  collection_name  = "${local.name}-kb"
}

# --- The collection itself (VECTORSEARCH) ---
resource "aws_opensearchserverless_collection" "kb" {
  name = local.collection_name
  type = "VECTORSEARCH"
}

# --- Encryption policy (use AWS-owned key for dev; swap to KMS for prod) ---
resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${local.name}-enc"
  type = "encryption"

  policy = jsonencode({
    Rules = [
      {
        ResourceType = "collection",
        Resource     = ["collection/${aws_opensearchserverless_collection.kb.name}"]
      }
    ],
    AWSOwnedKey = true
  })
}

# --- Network policy (dev: public; tighten later to VPCE or CIDRs) ---
resource "aws_opensearchserverless_security_policy" "network" {
  name = "${local.name}-net"
  type = "network"

  policy = jsonencode({
    Rules = [
      {
        ResourceType = "collection",
        Resource     = ["collection/${aws_opensearchserverless_collection.kb.name}"]
      },
      {
        ResourceType = "dashboard",
        Resource     = ["collection/${aws_opensearchserverless_collection.kb.name}"]
      }
    ],
    AllowFromPublic = true
  })
}

# --- Data access policy: let your Lambda roles call AOSS APIs ---
# If your lambda module outputs are named differently, update the Principals below.
resource "aws_opensearchserverless_access_policy" "data" {
  name = "${local.name}-data"
  type = "data"

  policy = jsonencode([
    {
      Description = "Lambda access for ingest + query",
      Rules = [
        {
          Resource   = ["collection/${aws_opensearchserverless_collection.kb.name}"],
          Permission = ["aoss:DescribeCollectionItems"]
        },
        {
          Resource   = ["index/${aws_opensearchserverless_collection.kb.name}/*"],
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
      Principal = [
        module.lambda_ingest.role_arn,
        module.lambda_query.role_arn
      ]
    }
  ])
}

# Helpful outputs
output "aoss_endpoint" {
  description = "Collection endpoint URL"
  value       = aws_opensearchserverless_collection.kb.collection_endpoint
}

output "aoss_dashboard" {
  description = "Dashboards URL"
  value       = aws_opensearchserverless_collection.kb.dashboard_endpoint
}
