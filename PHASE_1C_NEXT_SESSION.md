# Phase 1C — Next Session Checkpoint

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

**Phase 1C is not yet complete:** the above proves a clean deploy, and the app was
afterward fully torn down and confirmed clean (see "Current live AWS state" below).
What remains is the recreate → re-verify half of the cycle. See Guardrails below.

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

## Next task

Prove the recreate → re-verify half of the cycle (see "Remaining Phase 1C work" below).
The deploy was verified once and teardown is confirmed clean, but Phase 1C is not
complete until a fresh recreate from code is re-verified end-to-end.

## Remaining Phase 1C work

Build/wire/deploy/verify and teardown are both done (see sections above). The only
remaining task is the recreate → re-verify half of the cycle:

1. **Recreate infra from Terraform** — `environments/dev`, then `environments/dev/eks`,
   then `environments/dev/eks-platform`, in that order.
2. **Recreate `sarif-secrets` out-of-band** — same allowlisted keys as before
   (`SEATS_API_KEY`, `PUSHOVER_TOKEN`, `PUSHOVER_USER_KEY`).
3. **Reapply `k8s/overlays/eks`** using the already-committed image tag `5012516` — no
   rebuild needed, the image is still in ECR.
4. **Re-verify** — pod readiness, PVC `Bound` on `gp3`, ALB reachable, `/api/health` and
   frontend both `200` through the ALB, Pushover notification path.
5. **If that passes, mark Phase 1C complete.** No GitHub Actions changes — that stays
   deferred to Phase 1D.

## Guardrails

- No GitHub Actions changes until Phase 1D.
- Do not claim Phase 1C complete until Sarif is deployed, reachable through ALB, alerts are verified, and a teardown/recreate cycle is proven.
- Always tear down billable resources when stopping, in this exact order:
  1. App resources (Ingress, PVCs) — let controllers reclaim ALBs/volumes.
  2. `environments/dev/eks-platform` — `terraform destroy`
  3. `environments/dev/eks` — `terraform destroy`
  4. `environments/dev` — `terraform destroy -target=module.networking`
  5. Leave `environments/dev/ecr` intact.
