########################################
# General
########################################
variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
}

########################################
# Networking
########################################
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "availability_zones" {
  description = "List of AZs to deploy into"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
}

variable "data_subnet_cidrs" {
  description = "CIDR blocks for data-tier subnets"
  type        = list(string)
}

########################################
# EKS (used for subnet tagging now,
# cluster provisioned in Phase 2)
########################################
variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}
