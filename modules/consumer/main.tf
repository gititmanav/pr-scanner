# ---------------------------------------------------------
# SQS Consumer Lambda — drains the scan-jobs queue and launches
# a Fargate scanner task per message (connects Slice A -> Slice B).
# ---------------------------------------------------------

data "archive_file" "consumer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambdas/sqs_consumer"
  output_path = "${path.module}/consumer.zip"
}

resource "aws_lambda_function" "consumer" {
  function_name    = "${var.project}-consumer"
  role             = var.lab_role_arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.consumer_zip.output_path
  source_code_hash = data.archive_file.consumer_zip.output_base64sha256

  environment {
    variables = {
      ECS_CLUSTER         = var.ecs_cluster_arn
      TASK_DEFINITION_ARN = var.task_definition_arn
      SUBNET_ID           = var.subnet_id
      SECURITY_GROUP_ID   = var.security_group_id
      CONTAINER_NAME      = var.container_name
      S3_BUCKET           = var.s3_bucket
      DYNAMODB_TABLE      = var.dynamodb_table
    }
  }
}

# SQS triggers the consumer. batch_size = 1 so one bad message can't drop a whole batch.
resource "aws_lambda_event_source_mapping" "sqs_to_consumer" {
  event_source_arn = var.queue_arn
  function_name    = aws_lambda_function.consumer.arn
  batch_size       = 1
  enabled          = true
}
