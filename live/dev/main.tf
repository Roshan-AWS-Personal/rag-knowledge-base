resource "aws_s3_bucket" "rag-documents_bucket" {
  bucket = "ai-kb-${var.env}-docs"
  force_destroy = true
}