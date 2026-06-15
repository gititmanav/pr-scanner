terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_iam_role" "lab" {
  name = "LabRole"
}

# ============================================
# Shared resource names (deterministic).
# Passed as plain strings — NOT module outputs — so scanner and results don't
# reference each other and create a Terraform dependency cycle.
# Account is Manav's shared Learner Lab account (771014276560).
# ============================================
locals {
  account_id     = "771014276560"
  reports_bucket = "pr-scanner-reports-${local.account_id}" # created in scanner module (Manav)
  jobs_table     = "${var.project}-jobs"                    # created in results module (Sai)
}

# ============================================
# Networking Module (Manav - Slice B)
# ============================================
module "networking" {
  source  = "./modules/networking"
  region  = var.region
  project = var.project
}

# ============================================
# Scanner Module (Manav - Slice B)
# ============================================
module "scanner" {
  source            = "./modules/scanner"
  region            = var.region
  project           = var.project
  lab_role_arn      = data.aws_iam_role.lab.arn
  subnet_id         = module.networking.public_subnet_id
  security_group_id = module.networking.scanner_security_group_id
  account_id        = local.account_id
  reports_bucket    = local.reports_bucket
  dynamodb_table    = local.jobs_table
}

# ============================================
# Results Module (Sai - Slice C)
# ============================================
# HANDOFF S1: results currently creates its OWN reports bucket, whose name collides
# with the scanner bucket on this account -> `terraform apply` fails until Sai deletes
# that bucket resource, adds a `reports_bucket` variable, and we add the line:
#     reports_bucket = local.reports_bucket
# Also wire `scanner_cluster_arn = module.scanner.ecs_cluster_arn` for the EventBridge
# rule scoping (handoff S4).
module "results" {
  source       = "./modules/results"
  project      = var.project
  region       = var.region
  lab_role_arn = data.aws_iam_role.lab.arn
  alert_email  = var.alert_email
}

# ============================================
# Ingress Module (Vaishnavi - Slice A)
# ============================================
module "ingress" {
  source              = "./modules/ingress"
  project             = var.project
  region              = var.region
  lab_role_arn        = data.aws_iam_role.lab.arn
  dynamodb_table_name = local.jobs_table
}

# ============================================
# SQS -> Fargate Consumer (Vaishnavi - connects Slice A queue to Slice B scanner)
# ============================================
module "consumer" {
  source              = "./modules/consumer"
  project             = var.project
  lab_role_arn        = data.aws_iam_role.lab.arn
  queue_arn           = module.ingress.scan_jobs_queue_arn
  ecs_cluster_arn     = module.scanner.ecs_cluster_arn
  task_definition_arn = module.scanner.task_definition_arn
  subnet_id           = module.networking.public_subnet_id
  security_group_id   = module.networking.scanner_security_group_id
  container_name      = "scanner"
  s3_bucket           = local.reports_bucket
  dynamodb_table      = local.jobs_table
}
