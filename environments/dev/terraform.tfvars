# General
aws_region   = "us-west-2"
environment  = "dev"
project_name = "cloud-platform-lab"

# Networking
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["us-west-2a", "us-west-2b"]

# Public subnets — for NAT gateway, ALB, bastion (if needed)
public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]

# Private subnets — for EKS worker nodes and application pods
# Using /20 gives 4,091 IPs per subnet, plenty for EKS pod networking
private_subnet_cidrs = ["10.0.16.0/20", "10.0.32.0/20"]

# Data subnets — for RDS, ElastiCache (isolated from app traffic)
data_subnet_cidrs = ["10.0.100.0/24", "10.0.101.0/24"]

# EKS cluster name (used for subnet tagging now, cluster comes in Phase 2)
cluster_name = "cloud-platform-lab-dev"
