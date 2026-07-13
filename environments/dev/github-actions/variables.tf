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

variable "github_org" {
  description = "GitHub organization or user that owns the application repository"
  type        = string
}

variable "github_repository" {
  description = "GitHub repository name (without owner) whose workflow may assume the role"
  type        = string
}

variable "github_deploy_branch" {
  description = "Branch whose workflow runs may assume the role. workflow_dispatch runs needing AWS access must be launched from this branch; other branches and tags are denied."
  type        = string
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository the role may push images to"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name the role may describe (for the deploy preflight)"
  type        = string
}
