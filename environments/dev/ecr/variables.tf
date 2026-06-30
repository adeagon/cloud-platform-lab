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
