# Phase 1C — Complete

**Phase 1C is complete.** The full cycle — deploy, teardown, recreate from Terraform,
re-verify end-to-end, teardown again — has been proven. See "Recreate → re-verify"
below for the closing evidence. GitHub Actions / CI/CD remain deferred to Phase 1D.

## Completed state

- EKS baseline Terraform stack (`environments/dev/eks`) works end-to-end.
- ECR `sarif` repository exists and intentionally persists across teardowns.
- EKS platform components stack (`environments/dev/eks-platform`) was implemented and committed in commit `3c0f2be` with message "Add EKS platform components".
- EBS CSI driver was verified working as an EKS managed add-on with IRSA bound to `AmazonEBSCSIDriverPolicyV2`.
- `gp3` is the intended default StorageClass; `gp2` is de-defaulted by Terraform (`kubernetes_annotations`).
- Throwaway PVC test succeeded: PVC bound, EBS volume created, volume deleted on PVC cleanup (no orphan).
- AWS Load Balancer Controller was verified working with IRSA (`attach_load_balancer_controller_policy=true`).
- `alb` IngressClass and validating webhook were present.
- No real ALB was created (no Ingress deployed).
- All billable infrastructure was torn down cleanly in the correct order.
- ECR `sarif` repository remains intact.

## Phase 1C — live deployment verification (this session)

Sarif was deployed to EKS and verified end-to-end. Evidence:

- **Image:** built `linux/amd64` (confirmed via `docker buildx imagetools inspect`), pushed to ECR as `702516017596.dkr.ecr.us-west-2.amazonaws.com/sarif:5012516`.
- **Cluster/namespace:** `cloud-platform-lab-dev`, namespace `sarif`.
- **Pod:** `1/1 Running`, 0 restarts.
- **PVC:** `sarif-data` `Bound`, `gp3`, 1Gi.
- **ALB/Ingress:** ALB `k8s-sarif-sarif-443c05ee90` — `active`, `internet-facing`; target `10.0.59.135:3001` `healthy`.
- **App reachability through the ALB:** `GET /api/health` → `200 {"ok":true,"service":"sarif"}`; `GET /` → `200` (frontend HTML). Manual browser check confirmed the UI loads with no console CORS errors.
- **Pushover:** `sendNotification()` called via `kubectl exec` into the running pod returned `{"ok":true}`; notification received on phone. Same method as the Session 3 local-cluster verification.
- **CORS:** no failure observed, so no `configmap-cors-patch.yaml` was added — `CORS_ORIGIN` stays at the base default (frontend + API are same-origin behind one ALB).
- **`TRAVELPAYOUTS_TOKEN`:** intentionally excluded from `sarif-secrets` (only `SEATS_API_KEY`, `PUSHOVER_TOKEN`, `PUSHOVER_USER_KEY` were needed for this path) — `/api/cash` returns 503 as expected, not a defect.
- **HTTP-only ALB:** no TLS/ACM/Route 53/Cloudflare/custom domain — an intentional Phase 1C lab tradeoff. TLS is deferred to a future phase (ACM cert + HTTPS listener + host rule + Cloudflare CNAME).
- **GitHub Actions:** deferred to Phase 1D — no CI/CD changes made this session.

The above proves a clean deploy; the app was afterward fully torn down and confirmed
clean (see "Current live AWS state" below). The recreate → re-verify half of the cycle,
completing Phase 1C, is documented below under "Recreate → re-verify (closing session)".

## Current live AWS state

**Torn down and confirmed clean.** The app deployment above was verified, then fully
torn down in the documented order (Ingress → app resources/PVC → `eks-platform` →
`eks` → networking). Final cleanup checks, all passing:

| Resource | State |
|---|---|
| EKS clusters | None |
| NAT Gateways | None |
| Load Balancers (ALB/NLB) | None |
| Orphan available EBS volumes | None |
| Elastic IPs | None |
| ECR `sarif` repo | Intact (`702516017596.dkr.ecr.us-west-2.amazonaws.com/sarif`) |
| ECR image `sarif:5012516` | Intact, `ACTIVE` |

## Recreate → re-verify (closing session)

Fresh recreate from committed Terraform + Kustomize code, no source changes, no image
rebuild:

- **Networking** (`environments/dev`): `terraform plan`/`apply` — 24 added, 0 changed,
  0 destroyed.
- **EKS** (`environments/dev/eks`): 38 added, 0 changed, 0 destroyed. Cluster
  `cloud-platform-lab-dev`, 2 nodes `Ready`.
- **eks-platform** (`environments/dev/eks-platform`): 10 added, 0 changed, 0 destroyed.
  `gp3` default StorageClass, `gp2` de-defaulted, EBS CSI + AWS Load Balancer Controller
  pods `Running`, `alb` IngressClass present.
- **`sarif-secrets`** recreated out-of-band with only the 3 allowlisted keys
  (`SEATS_API_KEY`, `PUSHOVER_TOKEN`, `PUSHOVER_USER_KEY`) — confirmed via
  `kubectl get secret -o jsonpath` that no other keys were present.
- **App** (`kubectl apply -k k8s/overlays/eks`) using the already-committed image tag
  `5012516` — no rebuild.
- **Re-verification, all passed:**
  - Pod `1/1 Running`, 0 restarts.
  - PVC `sarif-data` `Bound` on `gp3`; backing EBS volume `in-use`, `gp3`, 1Gi.
  - ALB `k8s-sarif-sarif-443c05ee90` `active`, `internet-facing`; target `healthy`.
  - `GET /api/health` → `200 {"ok":true,"service":"sarif"}`; `GET /` → `200`.
  - Pushover: `sendNotification({ title, message })` called via `kubectl exec` →
    `{"ok":true}`; notification received with correct title/message (confirmed by
    screenshot — an earlier test call using the wrong, positional-args signature
    produced a hollow "undefined/undefined" notification and was corrected before
    treating this check as passed).
- Pre-completion confirmation: `git status` clean, `k8s/overlays/eks/kustomization.yaml`
  still pinned to tag `5012516`, zero Terraform/Kubernetes source diffs vs the checkpoint
  commit — the recreate was a faithful replay of committed code.

Torn down again after this verification (see teardown log / commit history for the
second teardown's clean-state confirmation).

## Guardrails

- No GitHub Actions changes until Phase 1D.
- Phase 1C is complete: Sarif was deployed, reachable through ALB, alerts verified, and a full teardown → recreate → re-verify → teardown cycle proven. These guardrails still apply to any future infra work on this stack.
- Always tear down billable resources when stopping, in this exact order:
  1. App resources (Ingress, PVCs) — let controllers reclaim ALBs/volumes.
  2. `environments/dev/eks-platform` — `terraform destroy`
  3. `environments/dev/eks` — `terraform destroy`
  4. `environments/dev` — `terraform destroy -target=module.networking`
  5. Leave `environments/dev/ecr` intact.
