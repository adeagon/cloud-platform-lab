########################################
# Data Sources — account / partition
########################################
# ARNs are constructed locally from these so the stack has NO dependency on the eks
# or ecr remote state. That decoupling is the point of the persistent/ephemeral split
# in docs/phase-1d-design.md: this IAM identity must remain appliable even after the
# EKS cluster and networking are torn down.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  # OIDC subject is pinned to a single repository + branch. workflow_dispatch runs that
  # need AWS access MUST be launched from this branch (main) — dispatches from any other
  # branch or a tag produce a different `sub` claim and are intentionally denied.
  oidc_subject = "repo:${var.github_org}/${var.github_repository}:ref:refs/heads/${var.github_deploy_branch}"

  # Constructed from stable names (not remote state) — see the data-source note above.
  ecr_repository_arn = "arn:${data.aws_partition.current.partition}:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_repository_name}"
  eks_cluster_arn    = "arn:${data.aws_partition.current.partition}:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
}

########################################
# GitHub Actions OIDC Provider
########################################
# Federated identity provider for GitHub Actions. token.actions.githubusercontent.com
# issues short-lived OIDC tokens the workflow exchanges for AWS credentials via
# sts:AssumeRoleWithWebIdentity — no static AWS access keys are ever stored in GitHub.
#
# thumbprint_list is intentionally omitted: for this well-known IdP, AWS validates the
# provider against its own trust store (aws provider ~> 6.0), so there is no thumbprint
# to pin or rotate here.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Name = "${var.project_name}-github-actions-oidc"
  }
}

########################################
# GitHub Actions IAM Role
########################################
# Assumed by the sarif CI/CD workflow via OIDC. The trust policy is pinned to a single
# repository and branch — repo:adeagon/sarif:ref:refs/heads/main — with no wildcards, so
# no other GitHub org, repo, ref, or tag can assume this role. pull_request events are
# excluded by design (PR jobs request no AWS credentials, per phase-1d-design.md Q3/Q4).

resource "aws_iam_role" "github_actions" {
  name        = "${var.project_name}-github-actions"
  description = "Assumed by the ${var.github_org}/${var.github_repository} GitHub Actions workflow (${var.github_deploy_branch}) via OIDC"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GitHubActionsOIDC"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = local.oidc_subject
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-github-actions"
  }
}

########################################
# GitHub Actions IAM Policy — ECR push + EKS describe
########################################
# Least-privilege permissions for the CI/CD workflow:
#   - authenticate to ECR (GetAuthorizationToken is not resource-scopable — must be "*")
#   - push image layers + manifests to the sarif repository only
#   - describe the cluster for the deploy preflight (phase-1d-design.md Q3): describe
#     returns ResourceNotFoundException when the cluster is intentionally torn down, which
#     requires this permission to be present so the preflight can tell "absent" from "denied".
#
# sts:GetCallerIdentity is intentionally NOT listed: it requires no IAM permission and is
# always allowed for any authenticated principal, so the workflow can call it for
# proof/debugging without an explicit grant.
#
# Kubernetes RBAC (the EKS access entry) is deliberately out of scope for this increment —
# this stack grants AWS-level permissions only.
#
# ecr:BatchGetImage is included alongside the push actions (not "pull" access in the general
# sense): docker/build-push-action's default provenance attestation pushes a manifest list
# referencing the image manifest, and BuildKit issues a HEAD request against that manifest
# during the push — which requires BatchGetImage. Without it, Increment 3's first real push
# failed with 403 Forbidden. GetDownloadUrlForLayer (actual layer pull) is still omitted until
# a concrete need appears.

resource "aws_iam_policy" "github_actions" {
  name        = "${var.project_name}-github-actions"
  description = "ECR push to ${var.ecr_repository_name} + eks:DescribeCluster for the GitHub Actions CI/CD role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuthToken"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPushToRepository"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeImages",
          "ecr:BatchGetImage"
        ]
        Resource = local.ecr_repository_arn
      },
      {
        Sid      = "EksDescribeCluster"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = local.eks_cluster_arn
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-github-actions"
  }
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions.arn
}
