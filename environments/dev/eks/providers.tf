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
# Ephemeral stack — destroy between sessions to control cost (cluster + nodes are ~$0.30/hr).
# The S3 bucket and DynamoDB lock table are owned by environments/dev (must be applied first).
# Destroying this stack does NOT remove the persistent VPC/NAT (environments/dev) or the
# ECR repo (environments/dev/ecr) — those are separate state files.

terraform {
  backend "s3" {
    bucket         = "cloud-platform-lab-tfstate"
    key            = "environments/dev/eks/terraform.tfstate"
    region         = "us-west-2"
    encrypt        = true
    dynamodb_table = "cloud-platform-lab-tflock"
  }
}
