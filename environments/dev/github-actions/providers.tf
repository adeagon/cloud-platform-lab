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
# Reads and writes state to the existing S3 backend (owned by environments/dev bootstrap).
# This stack is intentionally persistent: the GitHub Actions identity must survive EKS and
# networking teardown, so it deliberately reads NO other stack's remote state.

terraform {
  backend "s3" {
    bucket         = "cloud-platform-lab-tfstate"
    key            = "environments/dev/github-actions/terraform.tfstate"
    region         = "us-west-2"
    encrypt        = true
    dynamodb_table = "cloud-platform-lab-tflock"
  }
}
