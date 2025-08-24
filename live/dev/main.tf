resource "aws_s3_bucket" "rag-documents_bucket" {
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


