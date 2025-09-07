#############################
# Locals
#############################
locals {
  name               = "ai-kb-dev"
  upload_bucket_name = "ai-kb-dev-docs" # <- reuse existing bucket from your other project
}

#############################
# Use existing bucket (no new resource)
#############################
data "aws_s3_bucket" "uploads" {
  bucket = local.upload_bucket_name
}

#############################
# Queues (main + DLQ)
#############################
resource "aws_sqs_queue" "ingest_dlq" {
  name                       = "${local.name}-ingest-dlq"
  visibility_timeout_seconds = 90
  message_retention_seconds  = 1209600
}

resource "aws_sqs_queue" "ingest_queue" {
  name                       = "${local.name}-ingest-queue"
  visibility_timeout_seconds = 90
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingest_dlq.arn
    maxReceiveCount     = 5
  })
}

#############################
# Allow S3 -> SQS (queue policy)
#############################
data "aws_iam_policy_document" "s3_to_sqs" {
  statement {
    sid     = "AllowS3ToSendMessages"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    resources = [aws_sqs_queue.ingest_queue.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [data.aws_s3_bucket.uploads.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "ingest_queue_policy" {
  queue_url = aws_sqs_queue.ingest_queue.id
  policy    = data.aws_iam_policy_document.s3_to_sqs.json
}

#############################
# S3 Event Notification -> SQS
# (If you already manage notifications elsewhere, keep them consolidated.)
#############################
resource "aws_s3_bucket_notification" "uploads_to_sqs" {
  bucket = data.aws_s3_bucket.uploads.id

  queue {
    queue_arn     = aws_sqs_queue.ingest_queue.arn
    events        = ["s3:ObjectCreated:*"]
    # filter_prefix = "docs/"       # <- uncomment to only ingest a folder
    # filter_suffix = ".pdf"        # <- or limit by extension
  }

  # Ensure queue policy exists before S3 tries to set notifications
  depends_on = [aws_sqs_queue_policy.ingest_queue_policy]
}

#############################
# IAM for the ingest Lambda (attach to your existing exec role)
#############################

# If you have the role name already, set it here:
# variable "ingest_role_name" { type = string }
# data "aws_iam_role" "ingest_exec" { name = var.ingest_role_name }

# OR, if the role is defined in this module as aws_iam_role.ingest_exec, use that.
# Replace "ROLE_TO_ATTACH" below with one of:
#   data.aws_iam_role.ingest_exec.name
#   aws_iam_role.ingest_exec.name
locals {
  ingest_role_name_to_attach = aws_lambda_function.ingest.role
}

data "aws_iam_policy_document" "ingest_runtime_perms" {
  # SQS consume
  statement {
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility"
    ]
    resources = [aws_sqs_queue.ingest_queue.arn]
  }

  # S3 read/list on your existing bucket
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket"
    ]
    resources = [
      data.aws_s3_bucket.uploads.arn,
      "${data.aws_s3_bucket.uploads.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "ingest_runtime_perms" {
  name   = "${local.name}-ingest-runtime-perms"
  policy = data.aws_iam_policy_document.ingest_runtime_perms.json
}

resource "aws_iam_role_policy_attachment" "attach_ingest_runtime_perms" {
  role       = local.ingest_role_name_to_attach
  policy_arn = aws_iam_policy.ingest_runtime_perms.arn
}

#############################
# Event source mapping: SQS -> Lambda
#############################
resource "aws_lambda_event_source_mapping" "sqs_to_ingest" {
  event_source_arn                   = aws_sqs_queue.ingest_queue.arn
  function_name                      = aws_lambda_function.ingest.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
  enabled                            = true
}
