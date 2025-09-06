terraform {
  backend "s3" {
    bucket         = "${var.state_bucket}"
    key            = "${var.state_prefix}/dev/terraform.tfstate"
    region         = "${var.aws_region}"
  }
}