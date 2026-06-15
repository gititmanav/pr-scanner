variable "project" {
  default = "pr-scanner"
}

variable "region" {
  default = "us-east-1"
}

variable "lab_role_arn" {
  description = "ARN of the LabRole IAM role"
}

variable "alert_email" {
  description = "Email address for SNS alerts"
}

variable "reports_bucket" {
  description = "Name of the S3 reports bucket (owned by Manav's scanner module)"
  type        = string
}

variable "scanner_cluster_arn" {
  description = "ARN of Manav's ECS cluster"
  type        = string
}
