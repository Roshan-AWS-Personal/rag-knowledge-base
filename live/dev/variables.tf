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
  default = ["main, initial-config"] # add "dev" etc if needed
}
variable "project" {
  type = string
  default = "ai-kb"
}
variable "region"  { 
  type = string
  default = "ap-southeast-2" 
}

# where your code lives in the repo
variable "ingest_src_dir"    {
   type = string  
   default = "/lambda/ingest" 
   }
variable "query_src_dir"     {
   type = string
   default = "/lambda/query"
   }

variable "lambda_runtime"    {
   type = string
   default = "python3.12"
}
variable "lambda_timeout"    {
   type = number
   default = 30
}         # seconds
variable "lambda_memory_mb"  {
   type = number
   default = 512
}

# Env for both Lambdas
variable "bedrock_region"    {
   type = string
   default = "ap-southeast-2"
}
variable "embed_model_id"    {
   type = string
   default = "amazon.titan-embed-text-v2:0"
}
variable "chat_model_id"     {
   type = string
   default = "anthropic.claude-3-sonnet-20240229-v1:0"
}

variable "index_name"        {
   type = string
   default = "chunks"
}
variable "embed_dim"         {
   type = number
   default = 1024
}

variable "s3_prefix" {
  type    = string
  default = ""
}

variable "s3_suffix" {
  type    = string
  default = ".txt"
}

############################
# Vars (adjust as needed)
############################
variable "name"  { 
  default = "ai-kb-dev" 
}

variable "api_stage" { 
  description = "API stage name"
  default     = "$default" 
}
variable "domain_name" { 
  description = "Optional custom domain for CF" 
  default     = "" 
}
variable "acm_cert_arn" { 
  description = "us-east-1 cert ARN if using custom domain"
  default     = "" 
}