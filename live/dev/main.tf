resource "aws_s3_bucket" "rag-documents_bucket" {
  bucket = "ai-kb-${var.env}-docs"
  force_destroy = true
}

resource "aws_s3_bucket" "documents_bucket" {
  bucket = "s3-upload-documents"
  force_destroy = true
    tags = {
    Name = "document-upload-api-bucket"
  }
}