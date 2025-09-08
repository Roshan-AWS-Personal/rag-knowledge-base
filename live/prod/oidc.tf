############################################
# oidc.tf  (PROD ONLY)
# - Reuses existing GitHub OIDC provider
# - Creates a single GHA role: ${var.project}-${var.env}-gha-role
# - Attaches Admin (temp) + deny guardrails
############################################

# Who am I? (used to build ARNs for deny policy)
data "aws_caller_identity" "current" {}

# Reuse the OIDC provider you created in the console
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

############################################
# Trust policy: restrict to your repo + branches
############################################
locals {
  # Example output: ["repo:OWNER/REPO:ref:refs/heads/main", ...]
  repo_subs = [
    for b in var.allowed_branches :
    "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/${b}"
  ]
}

data "aws_iam_policy_document" "gha_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [
        "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/*"
      ]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [
        "repo:${var.github_owner}/s3-upload-api:ref:refs/heads/*"
      ]
    }
  }
}
############################################
# Role for GitHub Actions (prod)
############################################
resource "aws_iam_role" "gha" {
  name                 = "${var.project}-${var.env}-gha-role" # e.g., ai-kb-prod-gha-role
  assume_role_policy   = data.aws_iam_policy_document.gha_trust.json
  max_session_duration = 3600

  tags = {
    Project   = var.project
    Env       = var.env
    ManagedBy = "terraform"
  }
}

############################################
# Guardrails (explicit Deny always wins)
############################################

# 1) Deny actions outside the chosen region
# Only deny region-scoped services outside your region.
# Exclude global services so the deny doesn't hit them.
data "aws_iam_policy_document" "deny_outside_region" {
  statement {
    sid        = "DenyOutsideRegion"
    effect     = "Deny"

    # Deny everything EXCEPT these (global) services
    not_actions = [
      "iam:*",
      "sts:*",
      # optional but common global services to exclude as well:
      "cloudfront:*",
      "route53:*",
      "waf:*",
      "wafv2:*",
      "shield:*",
      "organizations:*",
      "support:*",
      "budgets:*",
      "globalaccelerator:*"
    ]

    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]  # ap-southeast-2
    }
  }
}

resource "aws_iam_policy" "deny_outside_region" {
  name   = "${var.project}-${var.env}-deny-outside-region"
  policy = data.aws_iam_policy_document.deny_outside_region.json
}

# 2) Deny deleting your Terraform state bucket/lock table (prod)
#    Uses your variables for precision, not wildcards.
data "aws_iam_policy_document" "deny_tf_state_deletes" {
  statement {
    sid    = "DenyDeleteTfState"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:DeleteObject",
      "s3:PutBucketVersioning",
      "dynamodb:DeleteTable"
    ]
    resources = [
      "arn:aws:s3:::${var.state_bucket}",
      "arn:aws:s3:::${var.state_bucket}/*",
      "arn:aws:dynamodb:${var.region}:${data.aws_caller_identity.current.account_id}:table/${var.dynamodb_table}"
    ]
  }
}

resource "aws_iam_policy" "deny_tf_state_deletes" {
  name   = "${var.project}-${var.env}-deny-tf-state-deletes"
  policy = data.aws_iam_policy_document.deny_tf_state_deletes.json
}

############################################
# Temporary: Admin for speed while building
# (replace with least-privilege later)
############################################
resource "aws_iam_role_policy_attachment" "admin_access" {
  role       = aws_iam_role.gha.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy_attachment" "attach_deny_outside_region" {
  role       = aws_iam_role.gha.name
  policy_arn = aws_iam_policy.deny_outside_region.arn
}

resource "aws_iam_role_policy_attachment" "attach_deny_tf_state_deletes" {
  role       = aws_iam_role.gha.name
  policy_arn = aws_iam_policy.deny_tf_state_deletes.arn
}

############################################
# Output: use this ARN in your GitHub secret ROLE_ARN_PROD
############################################
output "gha_role_arn" {
  description = "IAM role ARN to be assumed by GitHub Actions (prod)"
  value       = aws_iam_role.gha.arn
}
