########################################
# Remote State Backend
########################################
# Platform stack — owns Kubernetes/Helm resources that require a live cluster.
# Apply ORDER: (1) environments/dev [networking], (2) environments/dev/eks [cluster],
#              (3) this stack [platform components].
# Teardown ORDER (reverse): (1) app workloads/PVCs, (2) this stack,
#                           (3) eks, (4) networking target-destroy. ECR persists.

terraform {
  backend "s3" {
    bucket         = "cloud-platform-lab-tfstate"
    key            = "environments/dev/eks-platform/terraform.tfstate"
    region         = "us-west-2"
    encrypt        = true
    dynamodb_table = "cloud-platform-lab-tflock"
  }
}

########################################
# EKS cluster data — used for kubernetes provider and resource names
########################################
# Reads cluster endpoint + CA from AWS (needed to configure the kubernetes provider).
# Reads OIDC provider ARN and cluster name from eks remote state.
# One-directional dependency: eks-platform → eks (via remote state, no cycle).

data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = "cloud-platform-lab-tfstate"
    key    = "environments/dev/eks/terraform.tfstate"
    region = "us-west-2"
  }
}

# Persistent GitHub Actions IAM role (environments/dev/github-actions). Read-only:
# that stack reads no state back, so this is a one-directional reference, no cycle.
data "terraform_remote_state" "github_actions" {
  backend = "s3"
  config = {
    bucket = "cloud-platform-lab-tfstate"
    key    = "environments/dev/github-actions/terraform.tfstate"
    region = "us-west-2"
  }
}

data "aws_eks_cluster" "this" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

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
# Kubernetes Provider
########################################
# Authenticates against the live EKS cluster using short-lived credentials (~15 min token).
# No kubernetes resources in Gate 1; provider is configured here so it is ready for Gate 3+.

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

########################################
# Helm Provider
########################################
# Added at Gate 5 (LBC). Uses the same cluster credentials as the kubernetes provider.
# helm provider ~> 3.0 uses the nested kubernetes {} block for cluster authentication.

provider "helm" {
  # helm provider ~> 3.0 uses attribute syntax (= {}) instead of block syntax for kubernetes
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
