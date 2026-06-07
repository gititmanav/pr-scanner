output "scan_jobs_queue_url" {
  description = "URL of the main scan jobs queue"
  value       = aws_sqs_queue.scan_jobs.id
}

output "scan_jobs_queue_arn" {
  description = "ARN of the main scan jobs queue"
  value       = aws_sqs_queue.scan_jobs.arn
}

output "scan_jobs_dlq_url" {
  description = "URL of the dead letter queue"
  value       = aws_sqs_queue.scan_jobs_dlq.id
}

output "scan_jobs_dlq_arn" {
  description = "ARN of the dead letter queue"
  value       = aws_sqs_queue.scan_jobs_dlq.arn
}

output "scan_jobs_table_name" {
  description = "Name of the DynamoDB scan jobs table"
  value       = aws_dynamodb_table.scan_jobs.name
}

output "scan_jobs_table_arn" {
  description = "ARN of the DynamoDB scan jobs table"
  value       = aws_dynamodb_table.scan_jobs.arn
}

output "dispatch_function_url" {
  description = "Public URL for the Dispatch Lambda (GitHub webhook target)"
  value       = aws_lambda_function_url.dispatch.function_url
}

output "dispatch_function_name" {
  value = aws_lambda_function.dispatch.function_name
}
