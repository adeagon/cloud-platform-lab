output "ebs_csi_irsa_role_arn" {
  description = "IAM role ARN used by the EBS CSI driver service account (kube-system/ebs-csi-controller-sa)"
  value       = module.irsa_ebs_csi.arn
}

output "lbc_irsa_role_arn" {
  description = "IAM role ARN used by the AWS Load Balancer Controller service account (kube-system/aws-load-balancer-controller)"
  value       = module.irsa_lbc.arn
}
