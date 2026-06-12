variable "region" {
  default = "us-east-1"
}

variable "project" {
  default = "pr-scanner"
}

variable "alert_email" {
  description = "Email for SNS alerts"
}