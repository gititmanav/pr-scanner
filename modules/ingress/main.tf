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
  visibility_timeout_seconds = 300 # 5 min — how long a consumer holds a message before it reappears
  message_retention_seconds  = 345600 # 4 days

  # If a message fails to process maxReceiveCount times, send it to the DLQ
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.scan_jobs_dlq.arn
    maxReceiveCount     = 3
  })
}
