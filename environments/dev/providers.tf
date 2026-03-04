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
# IMPORTANT: Two-step setup process for remote state:
#
# Step 1 (first time only):
#   Comment out the entire "backend" block below.
#   Run: terraform init && terraform apply
#   This creates the S3 bucket and DynamoDB table using local state.
#
# Step 2:
#   Uncomment the "backend" block below.
#   Run: terraform init
#   Terraform will ask: "Do you want to migrate state?" — type "yes"
#   Your state is now stored remotely in S3 with locking via DynamoDB.
#
# After step 2, all future terraform commands use remote state automatically.

 terraform {
   backend "s3" {
     bucket         = "cloud-platform-lab-tfstate"
     key            = "environments/dev/terraform.tfstate"
     region         = "us-west-2"
     encrypt        = true
     dynamodb_table = "cloud-platform-lab-tflock"
   }
 }
