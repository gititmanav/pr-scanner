output "dynamodb_table_name" {
  value = aws_dynamodb_table.jobs.name
}

output "dynamodb_table_arn" {
  value = aws_dynamodb_table.jobs.arn
}

output "s3_bucket_name" {
  value = aws_s3_bucket.reports.bucket
}

output "s3_bucket_arn" {
  value = aws_s3_bucket.reports.arn
}