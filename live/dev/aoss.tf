################################
# aoss.tf — policies + collection
################################

# --- Encryption policy MUST exist before the collection ---
resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${local.name}-enc"
  type = "encryption"

  policy = jsonencode({
    Rules = [
      {
        ResourceType = "collection",
        Resource     = ["collection/${local.name}"]  # literal name
      }
    ],
    AWSOwnedKey = true
  })
}

# --- Network policy (payload MUST be an array) ---
resource "aws_opensearchserverless_security_policy" "network" {
  name = "${local.name}-net"
  type = "network"

  policy = jsonencode([
    {
      Rules = [
        { ResourceType = "collection", Resource = ["collection/${local.name}"] },
        { ResourceType = "dashboard",  Resource = ["collection/${local.name}"] }
      ],
      AllowFromPublic = true  # OK for dev; tighten later
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

# --- Data access policy (corrected permissions) ---
resource "aws_opensearchserverless_access_policy" "data" {
  name = "${local.name}-data"
  type = "data"

  policy = jsonencode([{
    Description = "Lambda data access on indices for ${local.name}"
    Rules = [
      # INDEX permissions — no DeleteDocument; use DeleteIndex/UpdateIndex
      {
        ResourceType = "index",
        Resource     = ["index/${local.name}/*"],
        Permission   = [
          "aoss:ReadDocument",
          "aoss:WriteDocument",
          "aoss:CreateIndex",
          "aoss:UpdateIndex",
          "aoss:DeleteIndex",
          "aoss:DescribeIndex"
        ]
      },
      # COLLECTION items describe — helpful for clients
      {
        ResourceType = "collection",
        Resource     = ["collection/${local.name}"],
        Permission   = ["aoss:DescribeCollectionItems"]
      }
    ],
    Principal = [
      aws_iam_role.ingest_exec.arn,
      aws_iam_role.query_exec.arn
    ]
  }])

  depends_on = [aws_opensearchserverless_collection.kb]
}

# --- Outputs ---
output "aoss_endpoint" {
  description = "Collection endpoint URL"
  value       = aws_opensearchserverless_collection.kb.collection_endpoint
}

output "aoss_dashboard" {
  description = "Dashboards URL"
  value       = aws_opensearchserverless_collection.kb.dashboard_endpoint
}
