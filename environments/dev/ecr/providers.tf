########################################
# AWS Provider
########################################
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      Project     = var.project_name
      ManagedBy   = "terraform"
    }
  }
}

########################################
# Remote State Backend
########################################
# Reads and writes state to the existing S3 backend.
# The bucket/table are owned by environments/dev (bootstrap), which must exist first.
# This stack is intentionally persistent — do NOT run terraform destroy without
# first removing prevent_destroy from the ECR repository resource.

terraform {
  backend "s3" {
    bucket         = "cloud-platform-lab-tfstate"
    key            = "environments/dev/ecr/terraform.tfstate"
    region         = "us-west-2"
    encrypt        = true
    dynamodb_table = "cloud-platform-lab-tflock"
  }
}
