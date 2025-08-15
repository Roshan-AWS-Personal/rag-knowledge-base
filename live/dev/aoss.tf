# aoss.tf

# --- Encryption policy MUST exist before the collection ---
resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${local.name}-enc"
  type = "encryption"

  policy = jsonencode({
    Rules = [
      {
        ResourceType = "collection",
        # Reference the literal name, not a resource attribute
        Resource     = ["collection/${local.name}"]
      }
    ],
    AWSOwnedKey = true
  })
}

# --- Network policy (MUST be an array) ---
resource "aws_opensearchserverless_security_policy" "network" {
  name = "${local.name}-net"
  type = "network"

  policy = jsonencode([
    {
      Rules = [
        {
          ResourceType = "collection",
          Resource     = ["collection/${local.name}"]
        },
        {
          ResourceType = "dashboard",
          Resource     = ["collection/${local.name}"]
        }
      ],
      AllowFromPublic = true
    }
  ])
}

# --- Collection (create AFTER policies) ---
resource "aws_opensearchserverless_collection" "kb" {
  name = local.name
  type = "VECTORSEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network
  ]
}

# --- Data access policy: allow your Lambda roles ---
resource "aws_opensearchserverless_access_policy" "data" {
  name = "${local.name}-data"
  type = "data"

  policy = jsonencode([
    {
      Description = "Lambda access for ingest + query",
      Rules = [
        {
          ResourceType = "collection",
          Resource     = ["collection/${local.name}"],
          Permission   = ["aoss:DescribeCollectionItems"]
        },
        {
          ResourceType = "index",
          Resource     = ["index/${local.name}/*"],
          Permission   = [
            "aoss:CreateIndex",
            "aoss:DeleteIndex",
            "aoss:UpdateIndex",
            "aoss:DescribeIndex",
            "aoss:ReadDocument",
            "aoss:WriteDocument"
          ]
        }
      ],
      # Use ROLE ARNs (execution roles), not function ARNs
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
