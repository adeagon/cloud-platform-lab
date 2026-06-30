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

**Phase 1C is not yet complete:** the above proves a clean deploy, but the teardown → recreate cycle has not yet been exercised this session. See Guardrails below.

## Current live AWS state

**Infra is currently running** — left up deliberately for the Phase 1C verification
above, not yet torn down:

| Resource | State |
|---|---|
| EKS cluster | `cloud-platform-lab-dev` — running |
| NAT Gateway | running |
| Load Balancer (ALB) | `k8s-sarif-sarif-443c05ee90` — active, internet-facing |
| EBS volume | bound to PVC `sarif-data` (`gp3`, 1Gi) |
| ECR `sarif` repo | Intact (`702516017596.dkr.ecr.us-west-2.amazonaws.com/sarif`) |

**Next action is teardown.** Once teardown is run and confirmed (no EKS cluster, no
NAT Gateway, no load balancers, no orphan EBS volumes, no stray Elastic IPs — ECR left
intact), this section should be updated again to record the cleanup-passed state.

## Next task

Prove the teardown → recreate cycle (see Guardrails). The live deployment is verified
(see above), but Phase 1C is not complete until teardown/recreate is proven.

## Remaining Phase 1C work

The build/wire/deploy/verify steps are done (see "live deployment verification" above).
What's left:

1. **Tear down app resources** — delete the Ingress and PVC so the AWS Load Balancer
   Controller and EBS CSI driver reclaim the ALB and the EBS volume before the
   controllers themselves go away.
2. **Tear down infra** — destroy `eks-platform`, then `eks`, then networking
   (`environments/dev -target=module.networking`), in that order. Leave
   `environments/dev/ecr` intact.
3. **Confirm cleanup** — no EKS cluster, no NAT Gateway, no load balancers, no orphan
   EBS volumes, no stray Elastic IPs. ECR `sarif` still intact.
4. **Recreate infra and app from code** — re-apply the three Terraform stacks, rebuild
   wasn't needed (image stays in ECR), redeploy the existing `k8s/overlays/eks`.
5. **Re-verify** — pod health, frontend, PVC binding, ALB reachability, and the
   Pushover path again on the freshly recreated stack.
6. **Mark Phase 1C complete** once step 5 passes. No GitHub Actions changes — that
   stays deferred to Phase 1D.

## Guardrails

- No GitHub Actions changes until Phase 1D.
- Do not claim Phase 1C complete until Sarif is deployed, reachable through ALB, alerts are verified, and a teardown/recreate cycle is proven.
- Always tear down billable resources when stopping, in this exact order:
  1. App resources (Ingress, PVCs) — let controllers reclaim ALBs/volumes.
  2. `environments/dev/eks-platform` — `terraform destroy`
  3. `environments/dev/eks` — `terraform destroy`
  4. `environments/dev` — `terraform destroy -target=module.networking`
  5. Leave `environments/dev/ecr` intact.
