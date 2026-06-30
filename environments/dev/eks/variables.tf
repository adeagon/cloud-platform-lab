variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "environment" {
  description = "Deployment environment (e.g. dev)"
  type        = string
}

variable "project_name" {
  description = "Project name prefix used for resource naming and tagging"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name; must match kubernetes.io/cluster/<name> tags on subnets"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster (e.g. '1.34')"
  type        = string
}

variable "endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public EKS API endpoint. Restrict to your IP/32."
  type        = list(string)
}
