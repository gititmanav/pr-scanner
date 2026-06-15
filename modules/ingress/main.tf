# ---------------------------------------------------------
# Ingress Module — SQS + Dead Letter Queue (Slice A)
# ---------------------------------------------------------

# Dead Letter Queue: messages land here after repeated failures
resource "aws_sqs_queue" "scan_jobs_dlq" {
  name                      = "${var.project}-scan-jobs-dlq"
  message_retention_seconds = 1209600 # 14 days — keep failed messages around to inspect
}

# Main queue: Dispatch Lambda sends scan-job messages here
resource "aws_sqs_queue" "scan_jobs" {
  name                       = "${var.project}-scan-jobs"
  visibility_timeout_seconds = 300    # 5 min — how long a consumer holds a message before it reappears
  message_retention_seconds  = 345600 # 4 days

  # If a message fails to process maxReceiveCount times, send it to the DLQ
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.scan_jobs_dlq.arn
    maxReceiveCount     = 3
  })
}

# ---------------------------------------------------------
# DynamoDB table removed — the canonical jobs table lives in the results module
# (Sai, "pr-scanner-jobs"). Dispatch references it by name via var.dynamodb_table_name.
# See INTEGRATION_PLAN.md task V1.
# ---------------------------------------------------------

# ---------------------------------------------------------
# Dispatch Lambda + Function URL
# ---------------------------------------------------------

# Zip the handler code at apply time
data "archive_file" "dispatch_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambdas/dispatch"
  output_path = "${path.module}/dispatch.zip"
}

resource "aws_lambda_function" "dispatch" {
  function_name = "${var.project}-dispatch"
  role          = var.lab_role_arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 30

  filename         = data.archive_file.dispatch_zip.output_path
  source_code_hash = data.archive_file.dispatch_zip.output_base64sha256

  environment {
    variables = {
      SCAN_JOBS_QUEUE_URL = aws_sqs_queue.scan_jobs.id
      SCAN_JOBS_TABLE     = var.dynamodb_table_name
      WEBHOOK_SECRET_NAME = "cs6620/github-webhook-secret"
    }
  }
}

# Public HTTPS endpoint for GitHub's webhook
resource "aws_lambda_function_url" "dispatch" {
  function_name      = aws_lambda_function.dispatch.function_name
  authorization_type = "NONE" # GitHub can't sign AWS-IAM requests; we verify via HMAC instead
}
