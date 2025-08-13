variable "aws_region" {
  type = string
}
variable "state_bucket" {
  type = string
}
variable "state_prefix" {
  type = string
}
variable "dynamodb_table" {
  type = string
}
variable "env" {
  type    = string
  default = "dev"
}

variable "github_owner"{
  type = string
  default = "Roshan-AWS-Personal"
}

variable "github_repo"{
  type = string
  default = "rag-knowledge-base"
}
variable "allowed_branches" {
  type    = list(string)
  default = ["main"] # add "dev" etc if needed
}
variable "project" {
  type = string
  default = "ai-kb"
}
variable "region"  { 
  type = string
  default = "ap-southeast-2" 
}
