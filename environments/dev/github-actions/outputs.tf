output "github_actions_role_arn" {
  description = "IAM role ARN the sarif workflow assumes via OIDC (role-to-assume for aws-actions/configure-aws-credentials)"
  value       = aws_iam_role.github_actions.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider (token.actions.githubusercontent.com)"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "github_actions_policy_arn" {
  description = "ARN of the customer-managed policy granting ECR push + eks:DescribeCluster"
  value       = aws_iam_policy.github_actions.arn
}
