terraform {
  backend "s3" {
    bucket         = "${var.state_bucket}"
    key            = "${var.state_prefix}/prod/terraform.tfstate"
    region         = "${var.aws_region}"
    dynamodb_table = "${var.dynamodb_table}"
  }
}