# Teardown Checklist

Run at the end of every work session, before closing, to stop billing. This is the actual
proven teardown order for the Phase 1C EKS stack — delete app resources first so the
controllers reclaim the ALB and EBS volume, then destroy the Terraform stacks in reverse
dependency order.

## App layer (Kubernetes)

- [ ] **Delete the Ingress first** and wait for the ALB + target group to be removed:
      `kubectl delete ingress sarif -n sarif`
      (poll `aws elbv2 describe-load-balancers` until the `k8s-sarif-*` ALB is gone)
- [ ] **Delete the app resources explicitly** (not `kubectl delete -k`):
      `kubectl -n sarif delete deployment sarif`
      `kubectl -n sarif delete service sarif`
      `kubectl -n sarif delete configmap sarif-config`
      `kubectl -n sarif delete pvc sarif-data`
      `kubectl -n sarif delete secret sarif-secrets`
- [ ] **Wait for the backing EBS volume to be deleted** — confirm no orphan `available`
      volume remains: `aws ec2 describe-volumes --filters Name=status,Values=available`

## Terraform stacks (reverse dependency order)

- [ ] **Destroy `environments/dev/eks-platform`** (EBS CSI, gp3 SC, AWS Load Balancer
      Controller, IRSA, GitHub Actions EKS access entry, `namespace/sarif`):
      `terraform -chdir=environments/dev/eks-platform apply` a
      `plan -destroy`
      (this also deletes the `sarif` Namespace — Terraform owns it, not Kustomize; no
      separate `kubectl delete namespace sarif` step, see `docs/phase-1d-design.md` Q8)
- [ ] **Destroy `environments/dev/eks`** (cluster, node group, IAM/OIDC, KMS, add-ons):
      `terraform -chdir=environments/dev/eks apply` a `plan -destroy`
- [ ] **Targeted destroy of networking** in `environments/dev` (leaves the S3 state bucket
      and DynamoDB lock table intact):
      `terraform -chdir=environments/dev plan -destroy -target=module.networking -out=tfplan`
      then apply

## Final AWS verification

- [ ] No EKS clusters: `aws eks list-clusters --region us-west-2`
- [ ] No active/pending NAT gateways: `aws ec2 describe-nat-gateways --region us-west-2`
- [ ] No load balancers: `aws elbv2 describe-load-balancers --region us-west-2`
- [ ] No orphan `available` EBS volumes:
      `aws ec2 describe-volumes --region us-west-2 --filters Name=status,Values=available`
- [ ] No Elastic IPs: `aws ec2 describe-addresses --region us-west-2`
- [ ] Glance at the Budgets dashboard

## Intentionally retained (do NOT destroy)

- [ ] ECR `sarif` repo + image `sarif:5012516` remain intact:
      `aws ecr describe-images --region us-west-2 --repository-name sarif --image-ids imageTag=5012516`
- [ ] S3 Terraform state bucket + DynamoDB lock table remain intact (they carry
      `prevent_destroy` and are excluded from the targeted networking destroy).
