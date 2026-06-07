variable "project" {
  description = "Project name prefix for resource naming"
  type        = string
  default     = "pr-scanner"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}
