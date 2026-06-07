output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.scanner.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_cluster_arn" {
  description = "ECS cluster ARN"
  value       = aws_ecs_cluster.main.arn
}

output "task_definition_arn" {
  description = "Task definition ARN"
  value       = aws_ecs_task_definition.scanner.arn
}

output "reports_bucket" {
  description = "S3 bucket for reports"
  value       = aws_s3_bucket.reports.bucket
}
