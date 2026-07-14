# Phase 1D Completion

**Phase 1D is complete.** GitHub Actions CI/CD via GitHub OIDC — build, test, publish to
ECR, and deploy to EKS — was implemented and proven live. The ephemeral AWS infrastructure
provisioned for validation was then torn down cleanly, while the persistent CI/CD
identity, ECR repository, and Terraform backend were retained. This document is the
execution/evidence record: what was implemented, proven, torn down, retained, and deferred.
See [`phase-1d-design.md`](phase-1d-design.md) for the design rationale and tradeoffs behind
these decisions.

## Final infrastructure state

| Component | Final state |
|---|---|
| GitHub Actions workflow | Retained |
| GitHub OIDC provider | Retained |
| GitHub Actions IAM role/policy | Retained |
| ECR repository and images | Retained |
| Terraform S3/DynamoDB backend | Retained |
| EKS cluster and node group | Destroyed |
| EKS platform add-ons/access entry | Destroyed |
| Sarif application resources | Destroyed |
| ALB and EBS volume | Destroyed |
| NAT gateway, project EIP, and VPC | Destroyed |

See "Teardown verification" and "Persistent resources retained" below for the detailed
evidence behind this summary.

## Phase summary

Final steady-state pipeline:

```
pull_request
  → validate

push to main
  → validate
  → publish immutable full-SHA image through GitHub OIDC to ECR

workflow_dispatch from main
  → validate
  → publish or reuse existing full-SHA image
  → deploy through the temporary self-hosted runner
  → EKS
  → ALB
  → application health verification
```

`deploy` is manual-only in the final steady-state workflow — it runs only on
`workflow_dispatch` from `main`. One automatic push-triggered deployment was deliberately
proven end-to-end before this trigger was corrected to `workflow_dispatch`-only (the runner
capable of running `deploy` is temporary and not on standby for an ordinary push). No static
AWS credentials are stored in GitHub at any point — both `publish` and `deploy` authenticate
via short-lived GitHub OIDC tokens exchanged for temporary AWS credentials.

## Scope completed

- Credential-free `validate` job — `npm ci` → `npm test` → `npm audit --omit=dev` (hard gate)
  → `npm run build`, on every `pull_request`, push, and `workflow_dispatch`, with zero AWS
  exposure.
- GitHub OIDC provider and IAM role with a repository/branch-scoped trust condition — no
  wildcards.
- ECR build and publish using immutable full `github.sha` tags — never `latest`, never the
  short SHA.
- Typed ECR image-existence check with idempotent reuse: every Publish run checks ECR for the
  full-SHA tag first and only builds/pushes if absent.
- EKS access entry for the GitHub Actions IAM role (external principal, not a pod — access
  entries, not IRSA).
- `AmazonEKSEditPolicy` scoped only to namespace `sarif` (namespace-scoped least-*damage*, not
  cluster-admin).
- Terraform ownership of namespace `sarif` — `k8s/overlays/eks` renders no Namespace object.
- Runtime Kustomize image injection (`kustomize edit set image`) without committing the image
  tag back to git — CI/CD, not GitOps.
- Temporary self-hosted deployment runner, required because the EKS API endpoint is
  restricted to the operator's `/32`.
- Rollout, PVC, ALB, and HTTP health verification (`/api/health`, `/`) as part of `deploy`.

## Final architecture

```
pull_request
    ↓
validate — ubuntu-latest, no AWS credentials

push to main
    ↓
validate
    ↓
publish — ubuntu-latest, OIDC → ECR

workflow_dispatch from main
    ↓
validate
    ↓
publish or reuse
    ↓
deploy — temporary [self-hosted, sarif-deploy]
    ↓
OIDC → EKS access entry → kubectl apply
    ↓
rollout → PVC gp3 → ALB → HTTP 200
```

- The temporary runner must be registered and online **before** `workflow_dispatch` is
  triggered.
- It is deregistered immediately after the deployment proof — never left running in between.
- The configured `deploy` job does not run on `pull_request` events.
- This is CI/CD, not GitOps: git stores deployment structure, ECR stores immutable artifacts,
  and Kubernetes stores which artifact is currently running — that last piece is not mirrored
  back into git.

## Major implementation decisions

**1. Persistent vs. ephemeral split.** The GitHub OIDC provider, IAM role, and IAM policy
live in the persistent `environments/dev/github-actions` stack — they don't depend on a
running cluster and shouldn't be recreated every teardown/recreate cycle. The EKS access
entry, access-policy association, and the `sarif` namespace live in the ephemeral
`eks-platform` stack, since they reference the live cluster directly and are rebuilt with it.

**2. OIDC trust.** The IAM role's trust policy pins the OIDC `sub` claim to the exact subject
`repo:adeagon/sarif:ref:refs/heads/main` — no wildcards, no other repo/branch/tag can assume
it, and no static AWS keys are ever stored in GitHub.

**3. Image strategy.** Every CI-built image is tagged with the full 40-character `github.sha`.
ECR tags are immutable; same-SHA reruns (`workflow_dispatch` re-triggered against a commit
already published) reuse the existing image rather than failing against the immutable tag.

**4. ECR provenance permission correction.** The first real push (Increment 3) failed with
`403 Forbidden`. Root cause: `docker/build-push-action`'s default provenance attestation
pushes a manifest list referencing the image manifest, and BuildKit issues a `HEAD` request
against that manifest during the push — which requires `ecr:BatchGetImage`. The fix
(commit `1749bdb`) added `ecr:BatchGetImage` alongside the existing push actions, scoped
narrowly to the `sarif` repository's own ARN (not `*`). `ecr:GetDownloadUrlForLayer` (actual
layer *pull*) remained denied — this was a manifest-inspection permission, not a general pull
grant.

**5. Namespace ownership.** `namespace.yaml` was moved out of `k8s/base` into
`k8s/overlays/local` (local/kind only); `k8s/overlays/eks` renders no Namespace object at
all. Terraform (`eks-platform`) is the sole owner of `namespace/sarif` on EKS. A clean
`terraform plan` ("No changes...") immediately after a live CI deployment proved no
ownership drift between Terraform and Kustomize.

**6. Deployment runner.** GitHub-hosted runners could complete OIDC and
`aws eks update-kubeconfig` (AWS control-plane APIs), but every `kubectl` call to the
cluster's own API server would hang and time out — the endpoint is restricted to the
operator's `/32`. A temporary self-hosted Mac runner, whose egress already matched the
allowlisted IP, provided reachability without widening the endpoint CIDR or allowlisting
GitHub's rotating runner IP ranges. This is a temporary lab operating model — registered
immediately before a dispatch, deregistered immediately after — not permanent production
infrastructure.

**7. Secret lifecycle.** Real secret values remain only in the operator's local, gitignored
`sarif/app/.env`. The Kubernetes Secret is restored manually (`--from-literal` allowlist) after
any cluster/namespace recreation. CI never creates, reads, lists, logs, or modifies Secret
values at any point. The Secret is destroyed along with the namespace during teardown — by
Terraform, not by CI.

**8. PVC lifecycle.** CI reapplies the committed PVC manifest idempotently
(`persistentvolumeclaim/sarif-data unchanged` on repeat applies). The same PVC and backing
EBS volume (`pvc-cf85018c-e1f8-4fe9-bdcb-ef8cc81b536a`) remained intact across a same-SHA
`workflow_dispatch` rerun. The `gp3` StorageClass's `Delete` reclaim policy released the
volume cleanly during the controlled teardown documented below.

## Implementation commits

**cloud-platform-lab:**
- `8b5fca4` — GitHub Actions OIDC IAM stack
- `1749bdb` — permit ECR manifest reads required by provenance push
- `4633144` — EKS CI access entry and Terraform-owned namespace
- `65e7d7b11ecf30d8d265e20bddfd22093c5dec0d` — Phase 1D architecture/evidence documentation

**sarif:**
- `9d1274f` — validation workflow
- `f5180f1` — OIDC/ECR publish workflow
- `3a3ea27983d38815f9fced71abb88cf2edf81a7d` — EKS deploy workflow
- `3713aa22e83bb2b820b1bc3c9d29225c14a7e8f4` — manual-only steady-state deploy trigger

## Workflow evidence

- **Initial automatic deployment:** run
  [29290997161](https://github.com/adeagon/sarif/actions/runs/29290997161) — proved automatic
  push-triggered deployment end-to-end, under the trigger condition since corrected.
- **Same-SHA `workflow_dispatch` idempotency proof:** run
  [29291839523](https://github.com/adeagon/sarif/actions/runs/29291839523).
- **Post-trigger-correction push:** run
  [29293062358](https://github.com/adeagon/sarif/actions/runs/29293062358), commit
  `3713aa22e83bb2b820b1bc3c9d29225c14a7e8f4` — `Validate` succeeded, `Publish image to ECR`
  succeeded, `Deploy to EKS` resolved immediately to `skipped`. No job queued waiting for a
  self-hosted runner.

Assumed role (both `publish` and `deploy`):
`arn:aws:sts::702516017596:assumed-role/cloud-platform-lab-github-actions/GitHubActions`

Image deployed during verification (retained in ECR; no longer running anywhere — the
cluster was subsequently torn down, see "Teardown verification" below):
`702516017596.dkr.ecr.us-west-2.amazonaws.com/sarif:3a3ea27983d38815f9fced71abb88cf2edf81a7d`

**Application evidence — point-in-time verification, captured before the controlled
teardown. None of the following (Deployment, Pod, PVC, ALB) exist post-teardown; see
"Teardown verification" below for the final, current state.**
- Deployment was `READY 1/1`, `AVAILABLE 1`; Pod was `Running`, `1/1` Ready, **0 restarts**.
- PVC `sarif-data` was `Bound` on `gp3`.
- ALB was created, `internet-facing`, target `healthy`.
- `GET /api/health` returned `200`; `GET /` returned `200`.
- Same-SHA reapply: every application resource reported `unchanged`.
- Same PVC volume remained intact across the reapply.

## Operational issues encountered

**1. ECR provenance push 403.** Caused by BuildKit's manifest-inspection `HEAD` request
requiring `ecr:BatchGetImage` (see decision 4 above). Corrected narrowly in IAM, scoped to the
`sarif` repository ARN. Retry succeeded.

**2. First-run ALB DNS cache.** Deployment, rollout, image verification, PVC verification, and
ALB target health had already succeeded when the first smoke-test attempt failed — caused by
temporary negative DNS caching on the operator Mac right after the ALB's initial creation.
Direct resolution and IP-based checks returned `200` throughout. A retry, and an independent
same-SHA run, both succeeded. No infrastructure or application defect was identified.

**3. Saved Terraform plan EKS-token expiry (this teardown session).** The `eks-platform`
destroy plan's `kubernetes`/`helm` providers authenticate via a short-lived (~15 min) EKS auth
token, frozen into the plan at `plan -destroy` time. The approval-review delay between
generating that plan and applying it exceeded the token's lifetime, so the four
`kubernetes`-provider resource destroys failed `Unauthorized` mid-apply; the AWS-provider
resources destroyed successfully in the same apply (6 of 13). A freshly regenerated plan
(new token) applied immediately afterward completed the remaining 7 resources cleanly. No
drift, state corruption, or unexpected resource change occurred at any point — verified by a
resource-by-resource `state list` comparison before and after.

**4. App teardown ordering.** The Ingress and app resources (Deployment, Service, ConfigMap,
PVC) were deleted manually while the AWS Load Balancer Controller and EBS CSI driver were
still running, so their finalizers cleared cleanly and the ALB/EBS volume were reclaimed
*before* `eks-platform` was destroyed. This avoided a namespace-Terminating/finalizer
deadlock that a pure Terraform namespace-cascade would have risked (the app resources are not
in Terraform state; only the namespace object is). Terraform remained the sole owner of the
`sarif` namespace throughout — it was destroyed by Terraform, not `kubectl delete namespace`.

## Teardown verification

Completed order:

1. **Application layer** — delete Ingress → wait for ALB deletion → delete Deployment,
   Service, ConfigMap, PVC → wait for EBS volume reclamation. (`sarif-secrets` was left in
   place; it has no external-controller finalizer and was destroyed naturally with the
   namespace in the next step.)
2. **`environments/dev/eks-platform`** — destroyed the namespace, GitHub Actions access
   entry/policy association, AWS Load Balancer Controller, EBS CSI add-on, `gp3`/`gp2`
   StorageClass resources, and both IRSA role/policy sets.
3. **`environments/dev/eks`** — destroyed the cluster, managed node group, add-ons, cluster
   KMS key/IAM, the cluster's own EKS OIDC provider, CloudWatch log group, and security
   groups.
4. **Targeted `module.networking` destroy** (`environments/dev`, `-target=module.networking`)
   — destroyed the NAT gateway, the project's EIP, the VPC, subnets, route tables, and
   internet gateway. The S3 state bucket and DynamoDB lock table were untouched, confirmed by
   their absence from the targeted plan.

Final results:
- No EKS clusters.
- No ALB/NLB.
- No orphan `available` EBS volumes.
- No running/stopped lab EC2 instances (former node-group instances confirmed `terminated`).
- No project NAT gateway.
- No project VPC/subnets/route tables/IGW.
- Project EIP released.
- Both repositories (`cloud-platform-lab`, `sarif`) clean throughout.

## Persistent resources retained

- ECR repository `sarif`.
- Historical tag `5012516` (Phase 1C manual push).
- Phase 1D full-SHA image tag `3a3ea27983d38815f9fced71abb88cf2edf81a7d`.
- GitHub Actions IAM role `cloud-platform-lab-github-actions` and its customer-managed policy.
- GitHub OIDC provider `token.actions.githubusercontent.com`.
- Trust policy still pinned to `repo:adeagon/sarif:ref:refs/heads/main`.
- S3 state bucket `cloud-platform-lab-tfstate`.
- DynamoDB lock table `cloud-platform-lab-tflock`.

Drift checks:
- `environments/dev/ecr` → **No changes.**
- `environments/dev/github-actions` → **No changes.**
- `environments/dev/eks` → clean full recreate plan (38 to add, 0 to change, 0 to destroy).
- Root `environments/dev` → networking-only recreate plan (24 to add); backend resources
  (`aws_s3_bucket.tfstate`, `aws_dynamodb_table.tflock`) show zero drift.
- `eks-platform` → **unable to plan** after EKS teardown, because its `cluster_name`/
  `cluster_oidc_provider_arn` lookups depend on the `eks` stack's remote-state outputs, which
  are now empty. This is expected lifecycle coupling between the two ephemeral stacks, not a
  defect.

## Deferred work

The following are explicitly non-blocking future work — Phase 1D is not incomplete because
of them:

- Cluster-absent deploy preflight.
- Managed Secret synchronization (AWS Secrets Manager / External Secrets / Secrets Store CSI).
- HTTPS, custom domain, and certificate management.
- Observability and alerting.
- Persistent or private-network deploy-runner architecture.
- Deployment concurrency and environment approval controls.
- Managed database migration and multi-replica application architecture.
- GitOps.

## Lessons learned

- Short-lived provider credentials (EKS auth tokens, ~15 min TTL) make saved-plan approval
  delays risky specifically for Kubernetes-provider destroy operations — a plan reviewed
  slowly enough can outlive the token it was generated with.
- Controller-managed external resources (ALB, EBS volumes) should be deleted while their
  controllers (LBC, EBS CSI) are still running, not left to a same-pass Terraform cascade that
  has no dependency edge forcing that ordering.
- Immutable SHA tags require an idempotent existence check (ECR) to make same-SHA reruns safe
  rather than failing against an immutable tag.
- Public-repository self-hosted runners should be temporary, narrowly labeled, and tightly
  time-boxed — registered only immediately before a deliberate dispatch, deregistered right
  after.
- Terraform ownership boundaries must align exactly with what Kustomize renders (or doesn't)
  to avoid perpetual `plan` drift — the namespace-ownership split (`base` vs. `local` vs.
  `eks` overlays) is the concrete example here.
- Persistent and ephemeral stacks should be separated strictly by lifecycle dependency, not by
  resource type alone — this is what let the OIDC identity survive every recreate cycle while
  the cluster-scoped access entry rebuilt cleanly each time.
