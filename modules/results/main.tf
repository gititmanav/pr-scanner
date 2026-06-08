data "aws_caller_identity" "current" {}

# DynamoDB Jobs Table
resource "aws_dynamodb_table" "jobs" {
  name         = "${var.project}-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    projection_type = "ALL"
  }

  tags = {
    Project = var.project
  }
}

# S3 Bucket for scan reports
resource "aws_s3_bucket" "reports" {
  bucket        = "${var.project}-reports-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Project = var.project
  }
}

# Zip the Lambda code
data "archive_file" "post_scan_zip" {
  type        = "zip"
  source_file = "${path.root}/lambdas/post_scan/handler.py"
  output_path = "${path.root}/lambdas/post_scan/handler.zip"
}

# Post-Scan Lambda
resource "aws_lambda_function" "post_scan" {
  function_name    = "${var.project}-post-scan"
  role             = var.lab_role_arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.post_scan_zip.output_path
  source_code_hash = data.archive_file.post_scan_zip.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      DYNAMODB_TABLE      = aws_dynamodb_table.jobs.name
      S3_BUCKET           = aws_s3_bucket.reports.bucket
      GITHUB_TOKEN_SECRET = "cs6620/github-token"
    }
  }

  tags = {
    Project = var.project
  }
}

# EventBridge rule - triggers when Fargate task stops
resource "aws_cloudwatch_event_rule" "fargate_stopped" {
  name        = "${var.project}-fargate-stopped"
  description = "Triggers post-scan Lambda when Fargate task stops"

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      lastStatus    = ["STOPPED"]
      stoppedReason = [{ prefix = "" }]
    }
  })
}

resource "aws_cloudwatch_event_target" "post_scan_target" {
  rule      = aws_cloudwatch_event_rule.fargate_stopped.name
  target_id = "PostScanLambda"
  arn       = aws_lambda_function.post_scan.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.post_scan.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.fargate_stopped.arn
}

# SNS topic for failure alerts
resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# CloudWatch alarm - fires when DLQ or Lambda errors spike
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project}-post-scan-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Post-scan Lambda has errors"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.post_scan.function_name
  }
}

# CloudWatch Dashboard
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "Post-Scan Lambda Invocations"
          region  = var.region
          metrics = [["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.post_scan.function_name]]
          period  = 300
          stat    = "Sum"
          view    = "timeSeries"
          annotations = { horizontal = [] }
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "Post-Scan Lambda Errors"
          region  = var.region
          metrics = [["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.post_scan.function_name]]
          period  = 300
          stat    = "Sum"
          view    = "timeSeries"
          annotations = { horizontal = [] }
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "Post-Scan Lambda Duration"
          region  = var.region
          metrics = [["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.post_scan.function_name]]
          period  = 300
          stat    = "Average"
          view    = "timeSeries"
          annotations = { horizontal = [] }
        }
      }
    ]
  })
}