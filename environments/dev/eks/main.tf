########################################
# Networking — remote state
########################################
# Reads VPC outputs from the environments/dev stack rather than re-creating them.
# Requires environments/dev to be applied first.

data "terraform_remote_state" "networking" {
  backend = "s3"
  config = {
    bucket = "cloud-platform-lab-tfstate"
    key    = "environments/dev/terraform.tfstate"
    region = "us-west-2"
  }
}

########################################
# EKS Cluster
########################################
# Using terraform-aws-modules/eks/aws v21 (latest as of 2026-06-29: v21.24.0).
#
# v21 RENAMED several arguments vs. v20 (the version most online guides document):
#   cluster_name    → name
#   cluster_version → kubernetes_version
#   cluster_endpoint_public_access → endpoint_public_access
#
# Nodes run in private subnets (NAT-routed for image pulls, no public IPs).
# Subnets already carry: kubernetes.io/cluster/cloud-platform-lab-dev=shared
#                        kubernetes.io/role/internal-elb=1
# (set by modules/networking).
#
# Auth mode: API (not aws-auth ConfigMap). enable_cluster_creator_admin_permissions
# creates an EKS access entry granting the Terraform caller cluster-admin, so kubectl
# works immediately after apply without any additional RBAC configuration.
#
# Phase 1D note: this stack does NOT reference the ECR repository URL.
# Wiring image refs into k8s/overlays/eks is Phase 1C Session 2+ work.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name       # cloud-platform-lab-dev
  kubernetes_version = var.kubernetes_version # 1.34

  vpc_id     = data.terraform_remote_state.networking.outputs.vpc_id
  subnet_ids = data.terraform_remote_state.networking.outputs.private_subnet_ids

  # EKS API auth — no aws-auth ConfigMap; access via IAM access entries only
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true # grants Terraform caller cluster-admin

  # Public endpoint restricted to your IP; private endpoint for in-VPC node communication
  endpoint_public_access       = true
  endpoint_private_access      = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # Control-plane logs with 7-day retention (dev cost control)
  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 7

  # System add-ons — required; v21 sets bootstrap_self_managed_addons = false,
  # so vpc-cni, kube-proxy, and coredns must be declared explicitly here.
  # before_compute = true creates aws_eks_addon.before_compute resources that
  # Terraform deploys before node groups, ensuring aws-node is in the cluster
  # when nodes boot so the CNI initializes and nodes reach Ready.
  addons = {
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    kube-proxy = {
      most_recent    = true
      before_compute = true
    }
    coredns = {
      most_recent = true
      # before_compute = false (default): Deployment, needs Ready nodes to schedule
    }
  }

  # Managed node group: 2× t3.medium, fixed size, AL2023
  # Node IAM role receives AmazonEC2ContainerRegistryReadOnly (module default) so nodes
  # can pull images from the sarif ECR repo in environments/dev/ecr.
  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 2
      desired_size   = 2
    }
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}
