variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "pr-scanner"
}

variable "lab_role_arn" {
  description = "ARN of the LabRole"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for Fargate tasks"
  type        = string
}

variable "security_group_id" {
  description = "Security group ID for Fargate tasks"
  type        = string
}

variable "reports_bucket" {
  description = "S3 bucket name for scan reports"
  type        = string
  default     = ""
}

variable "dynamodb_table" {
  description = "DynamoDB table name for scan jobs"
  type        = string
  default     = "pr-scanner-jobs"
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
}
