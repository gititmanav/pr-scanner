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
