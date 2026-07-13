########################################
# EBS CSI IRSA Role
########################################
# The IRSA module creates the IAM role and trust policy only.
# We do NOT use attach_ebs_csi_policy = true because that generates an inline
# customer-managed policy — we want the AWS-managed AmazonEBSCSIDriverPolicyV2 instead.
# The 'policies' map attaches the managed policy via aws_iam_role_policy_attachment.additional.
#
# Gate 1 hard stop: the plan must show policy_arn =
#   arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicyV2
# (NOT service-role/AmazonEBSCSIDriverPolicy V1, NOT an inline policy).

module "irsa_ebs_csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                  = "${var.project_name}-ebs-csi-irsa"
  attach_ebs_csi_policy = false # do NOT generate inline policy

  # Attach AWS-managed V2 policy via the module's additional-policies mechanism
  policies = {
    ebs_csi = "arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicyV2"
  }

  # Trust policy: allow the EBS CSI controller service account to assume this role
  oidc_providers = {
    main = {
      provider_arn               = data.terraform_remote_state.eks.outputs.cluster_oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = {
    Component = "ebs-csi-driver"
  }
}

########################################
# EBS CSI Driver — EKS Managed Add-on
########################################
# Managed as a standalone aws_eks_addon (not via the module.eks addons block) to avoid
# the dependency cycle that would arise if eks's module needed the IRSA ARN while the
# IRSA module needed the OIDC ARN from eks.
#
# service_account_role_arn instructs the add-on to annotate ebs-csi-controller-sa with
# the IRSA role ARN automatically on installation.

data "aws_eks_addon_version" "ebs_csi" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = data.aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = data.aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = data.aws_eks_addon_version.ebs_csi.version
  service_account_role_arn = module.irsa_ebs_csi.arn

  # OVERWRITE lets the add-on install cleanly even if a conflicting field exists
  # (e.g. a stale annotation from a prior partial install).
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Component = "ebs-csi-driver"
  }
}

########################################
# gp3 default StorageClass
########################################
# Provisioner ebs.csi.aws.com requires the EBS CSI driver add-on to be active.
# WaitForFirstConsumer defers volume creation until a pod is scheduled, which allows
# EBS to pick the correct AZ for the node — required with multi-AZ node groups.
# encrypted=true ensures all gp3 volumes use AES-256 at rest by default.

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}

########################################
# gp2 StorageClass — remove default annotation
########################################
# The legacy in-tree gp2 StorageClass exists but is NOT currently marked default
# (is-default-class=unset). We manage its annotation explicitly so the "exactly one
# default StorageClass = gp3" invariant is Terraform-enforced and drift-detectable.
# kubernetes_annotations patches ONLY the annotations field — it does NOT replace,
# recreate, or delete the gp2 StorageClass itself.

resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"

  metadata {
    name = "gp2"
  }

  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  force = true # take ownership of this annotation even if previously set by another manager
}

########################################
# AWS Load Balancer Controller — IRSA Role
########################################
# Uses the module preset attach_load_balancer_controller_policy = true.
# Verified (Gate 5 policy diff): module preset covers all 80 unique actions in the
# upstream v3.4.0 iam_policy.json with equivalent tag-scoped conditions. No divergence.

module "irsa_lbc" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                                   = "${var.project_name}-lbc-irsa"
  attach_load_balancer_controller_policy = true

  # Trust policy: allow the LBC service account to assume this role via IRSA
  oidc_providers = {
    main = {
      provider_arn               = data.terraform_remote_state.eks.outputs.cluster_oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = {
    Component = "aws-load-balancer-controller"
  }
}

########################################
# LBC Kubernetes Service Account (Terraform-managed)
########################################
# Created as a first-class Terraform resource so the IRSA annotation is visible in
# Terraform state and drift-detectable — not delegated to Helm (serviceAccount.create=false).

resource "kubernetes_service_account_v1" "lbc" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = module.irsa_lbc.arn
    }
    labels = {
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
      "app.kubernetes.io/component" = "controller"
    }
  }
}

########################################
# AWS Load Balancer Controller — Helm Release
########################################
# Chart 3.4.0 / appVersion v3.4.0 (current latest as of 2026-06-30).
# serviceAccount.create=false: SA is managed by Terraform above.
# vpcId is read from the live cluster's vpc_config so it is always consistent with
# the cluster that was actually applied (not a separately-typed variable).

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.4.0"
  namespace  = "kube-system"

  # helm provider ~> 3.0: set is now a list attribute (nested_type), not a block
  set = [
    {
      name  = "clusterName"
      value = data.aws_eks_cluster.this.name
    },
    {
      name  = "region"
      value = var.aws_region
    },
    {
      name  = "vpcId"
      value = data.aws_eks_cluster.this.vpc_config[0].vpc_id
    },
    {
      name  = "serviceAccount.create"
      value = "false"
    },
    {
      name  = "serviceAccount.name"
      value = kubernetes_service_account_v1.lbc.metadata[0].name
    },
  ]

  depends_on = [kubernetes_service_account_v1.lbc]
}

########################################
# sarif Namespace — Terraform-owned on EKS (Q8)
########################################
# eks-platform is the sole owner of namespace/sarif on EKS going forward. Kustomize's
# k8s/base no longer lists namespace.yaml as a resource, and k8s/overlays/eks does not
# reintroduce it — only k8s/overlays/local carries its own copy (for kind). Labels
# mirror k8s/overlays/local/namespace.yaml so there is no drift between environments.

resource "kubernetes_namespace_v1" "sarif" {
  metadata {
    name = "sarif"
    labels = {
      "app.kubernetes.io/name"    = "sarif"
      "app.kubernetes.io/part-of" = "sarif"
    }
  }
}

########################################
# GitHub Actions CI/CD role — EKS access entry
########################################
# The GitHub Actions role is an external IAM principal (not a pod), so IRSA does not
# apply here — access entries are the RBAC mechanism on this cluster, which already
# runs authentication_mode = "API" (no aws-auth ConfigMap path). principal_arn comes
# from the persistent github-actions stack's remote state, not hardcoded.

resource "aws_eks_access_entry" "github_actions" {
  cluster_name  = data.aws_eks_cluster.this.name
  principal_arn = data.terraform_remote_state.github_actions.outputs.github_actions_role_arn
  type          = "STANDARD"

  tags = {
    Component = "github-actions-cicd"
  }
}

########################################
# GitHub Actions CI/CD role — namespace-scoped EKSEditPolicy (Q7)
########################################
# AmazonEKSEditPolicy scoped to namespace "sarif" only — namespace-scoped least-damage,
# not cluster-admin. Broader than a custom deploy-specific RBAC policy; accepted as an
# MVP limitation per the design doc (custom RBAC is future hardening, not implemented here).

resource "aws_eks_access_policy_association" "github_actions_edit" {
  cluster_name  = data.aws_eks_cluster.this.name
  principal_arn = data.terraform_remote_state.github_actions.outputs.github_actions_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["sarif"]
  }

  depends_on = [aws_eks_access_entry.github_actions]
}
