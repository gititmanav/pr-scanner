terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket         = "cs6620-prscanner-tfstate-771014276560"
    key            = "pr-scanner/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "cs6620-prscanner-tflock"
    encrypt        = true
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
  source             = "./modules/scanner"
  region             = var.region
  project            = var.project
  lab_role_arn       = data.aws_iam_role.lab.arn
  subnet_id          = module.networking.public_subnet_id
  security_group_id  = module.networking.scanner_security_group_id
  account_id         = "771014276560"
}
