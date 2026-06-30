output "ecr_repository_url" {
  description = "Full ECR URL for docker push/pull and k8s/overlays/eks kustomize image ref"
  value       = aws_ecr_repository.sarif.repository_url
}

output "ecr_repository_arn" {
  description = "ARN of the sarif ECR repository"
  value       = aws_ecr_repository.sarif.arn
}
