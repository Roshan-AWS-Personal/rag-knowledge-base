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

# === AOSS data access policy: allow ingest role to create/read/write the index ===
resource "aws_opensearchserverless_access_policy" "kb_data_access" {
  name = "kb-data-access"
  type = "data"

  policy = jsonencode({
    Description = "Allow ingest lambda to manage/read/write the kb indexes"
    Rules = [
      # Index-level permissions (all indexes in this collection, or scope to 'chunks' if you want)
      {
        ResourceType = "index"
        Resource     = ["index/${aws_opensearchserverless_collection.kb.name}/*"]
        Permission   = [
          "aoss:CreateIndex",
          "aoss:DescribeIndex",
          "aoss:ReadDocument",
          "aoss:WriteDocument",
          "aoss:DeleteDocument"
        ]
      },
      # Collection-level describe is commonly needed for clients
      {
        ResourceType = "collection"
        Resource     = ["collection/${aws_opensearchserverless_collection.kb.name}"]
        Permission   = [
          "aoss:DescribeCollectionItems"
        ]
      }
    ]
    Principal = [
      aws_iam_role.ingest_exec.arn,
      aws_iam_role.query_exec.arn
    ]
  })
}






output "aoss_endpoint" {
  description = "Collection endpoint URL"
  value       = aws_opensearchserverless_collection.kb.collection_endpoint
}

output "aoss_dashboard" {
  description = "Dashboards URL"
  value       = aws_opensearchserverless_collection.kb.dashboard_endpoint
}
