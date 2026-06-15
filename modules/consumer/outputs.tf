output "consumer_function_name" {
  description = "Name of the SQS consumer Lambda"
  value       = aws_lambda_function.consumer.function_name
}

output "consumer_function_arn" {
  description = "ARN of the SQS consumer Lambda"
  value       = aws_lambda_function.consumer.arn
}
