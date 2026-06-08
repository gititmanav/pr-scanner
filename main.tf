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
  account_id        = "771014276560"
}

# ============================================
# Results Module (Sai - Slice C)
# ============================================
module "results" {
  source       = "./modules/results"
  project      = var.project
  region       = var.region
  lab_role_arn = data.aws_iam_role.lab.arn
  alert_email  = var.alert_email
}