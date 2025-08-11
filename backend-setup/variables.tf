variable "aws_region" {
  type        = string
  description = "AWS region for the state backend"
}

variable "state_bucket_name" {
  type        = string
  description = "S3 bucket name to hold Terraform state"
}

variable "dynamodb_table_name" {
  type        = string
  description = "DynamoDB table to lock Terraform state"
}
