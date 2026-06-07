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
    use_lockfile = "cs6620-prscanner-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
}

data "aws_iam_role" "lab" {
  name = "LabRole"
}
