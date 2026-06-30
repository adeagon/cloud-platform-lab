output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_oidc_provider_arn" {
  description = "OIDC provider ARN — used for IRSA in later Phase 1C sessions"
  value       = module.eks.oidc_provider_arn
}

output "node_iam_role_arn" {
  description = "IAM role ARN for the managed node group; verify ECR read policy is attached"
  value       = module.eks.eks_managed_node_groups["default"].iam_role_arn
}

output "update_kubeconfig_command" {
  description = "Run this after apply to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
