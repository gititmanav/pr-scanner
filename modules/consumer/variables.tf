variable "project" {
  description = "Project name prefix for resource naming"
  type        = string
  default     = "pr-scanner"
}

variable "lab_role_arn" {
  description = "ARN of the pre-existing LabRole"
  type        = string
}

variable "queue_arn" {
  description = "ARN of the SQS scan-jobs queue (event source)"
  type        = string
}

variable "ecs_cluster_arn" {
  description = "ARN of the ECS cluster to run scanner tasks in"
  type        = string
}

variable "task_definition_arn" {
  description = "ARN of the scanner Fargate task definition"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID for the Fargate task"
  type        = string
}

variable "security_group_id" {
  description = "Security group ID for the Fargate task"
  type        = string
}

variable "container_name" {
  description = "Container name in the scanner task definition (overrides target this)"
  type        = string
  default     = "scanner"
}

variable "s3_bucket" {
  description = "Reports bucket name passed to the scanner container"
  type        = string
}

variable "dynamodb_table" {
  description = "Jobs table name passed to the scanner container"
  type        = string
}
