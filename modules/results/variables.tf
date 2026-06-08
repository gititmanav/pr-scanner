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