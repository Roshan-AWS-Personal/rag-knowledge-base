resource "aws_sqs_queue" "ingest_dlq" {
  name                      = "${local.name}-ingest-dlq"
  visibility_timeout_seconds = 90
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "ingest_queue" {
  name = "${local.name}-ingest-queue"
  visibility_timeout_seconds = 90

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingest_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_lambda_event_source_mapping" "sqs_to_ingest" {
  event_source_arn                        = aws_sqs_queue.ingest_queue.arn
  function_name                           = aws_lambda_function.ingest.arn
  batch_size                              = 10
  maximum_batching_window_in_seconds      = 5
  function_response_types                 = ["ReportBatchItemFailures"]
}


data "aws_iam_policy_document" "ingest_runtime_perms" {
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

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.rag_documents_bucket.arn,
      "${aws_s3_bucket.rag_documents_bucket.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "ingest_runtime_perms" {
  name   = "${local.name}-ingest-runtime-perms"
  policy = data.aws_iam_policy_document.ingest_runtime_perms.json
}

# Only attach when you provide a role name
data "aws_iam_role" "ingest_exec" {
  count = aws_iam_role.ingest_exec.name == null ? 0 : 1
  name  = aws_iam_role.ingest_exec.name
}

resource "aws_iam_role_policy_attachment" "attach_ingest_runtime_perms" {
  count      = aws_iam_role.ingest_exec.name == null ? 0 : 1
  role       = data.aws_iam_role.ingest_exec[0].name
  policy_arn = aws_iam_policy.ingest_runtime_perms.arn
}
