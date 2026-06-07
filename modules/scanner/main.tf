# ============================================
# ECR Repository (where Docker images live)
# ============================================
resource "aws_ecr_repository" "scanner" {
  name         = "${var.project}-scanner"
  force_delete = true

  tags = {
    Name = "${var.project}-scanner"
  }
}

# ============================================
# ECS Cluster
# ============================================
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  tags = {
    Name = "${var.project}-cluster"
  }
}

# ============================================
# CloudWatch Log Group (for Fargate task logs)
# ============================================
resource "aws_cloudwatch_log_group" "scanner" {
  name              = "/ecs/${var.project}-scanner"
  retention_in_days = 7

  tags = {
    Name = "${var.project}-scanner-logs"
  }
}

# ============================================
# ECS Fargate Task Definition
# ============================================
resource "aws_ecs_task_definition" "scanner" {
  family                   = "${var.project}-scanner"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = var.lab_role_arn
  task_role_arn            = var.lab_role_arn

  container_definitions = jsonencode([
    {
      name      = "scanner"
      image     = "${aws_ecr_repository.scanner.repository_url}:latest"
      essential = true
      environment = [
        { name = "S3_BUCKET", value = var.reports_bucket },
        { name = "DYNAMODB_TABLE", value = var.dynamodb_table },
        { name = "AWS_DEFAULT_REGION", value = var.region }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.scanner.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "scanner"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project}-scanner-task"
  }
}

# ============================================
# S3 Bucket for scan reports
# ============================================
resource "aws_s3_bucket" "reports" {
  bucket        = "${var.project}-reports-${var.account_id}"
  force_destroy = true

  tags = {
    Name = "${var.project}-reports"
  }
}
