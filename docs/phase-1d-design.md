# Phase 1D — GitHub Actions CI/CD Design Decisions

**Status:** Increments 1–5 implemented and proven live (see "Increment 5 — proven final architecture" below). Increments 1–4 shipped the validate/publish pipeline, GitHub OIDC IAM stack, and the Terraform-owned `sarif` namespace with a namespace-scoped EKS access entry. Increment 5 added the `deploy` job and proved the complete path end-to-end, twice, against the live cluster.

**Phase 1C status:** Complete (commit `ce2f72b`). EKS cluster, ECR repo, and the full deploy → teardown → recreate from committed code → re-verify → teardown cycle were proven with zero source changes required on the second pass.

**Phase 1D goal:** GitHub Actions CI/CD via GitHub OIDC (no static AWS keys) — build, test, push to ECR, deploy to EKS on merge to `main`, with correct behavior when the lab cluster is intentionally torn down between sessions.

---

## 1. Ownership split: persistent vs. ephemeral

| Resource | Lifecycle | Stack |
|---|---|---|
| GitHub OIDC provider (`token.actions.githubusercontent.com`) | Persistent | `environments/dev/github-actions` (new) |
| GitHub Actions IAM role + trust policy | Persistent | `environments/dev/github-actions` (new) |
| IAM policy: ECR push, `eks:DescribeCluster` | Persistent | `environments/dev/github-actions` (new) |
| EKS access entry for the GitHub Actions role | Ephemeral | `eks-platform` |
| EKS access policy association (`AmazonEKSEditPolicy`, namespace-scoped) | Ephemeral | `eks-platform` |
| `sarif` Namespace object | Ephemeral | `eks-platform` (Terraform-managed going forward — see Q8) |

**Rationale:** the IAM identity and its base permissions don't depend on a running cluster and shouldn't be recreated every teardown/recreate cycle — that just churns a role ARN for no benefit. Everything that references the live cluster (`cluster_name`, access entries, namespace) is tied to the cluster's own lifecycle and gets rebuilt with it, consistent with the existing LBC / EBS-CSI IRSA pattern already in `eks-platform`.

---

## Q1 — Workflow ownership

**Decision:** Hybrid. The workflow lives in `sarif`. `sarif` builds, tests, and pushes the image. `cloud-platform-lab` remains the source of truth for Terraform and Kubernetes manifests. The deploy step performs a second `actions/checkout` of `cloud-platform-lab` and applies the overlay from there. The second checkout requires no additional PAT or GitHub App credential because `cloud-platform-lab` is public.

**Rejected:** full split across two repos with `repository_dispatch` triggering. The default `GITHUB_TOKEN` cannot trigger a workflow in a different repository — that requires a PAT or GitHub App installation token. For a solo project, that's a credential to provision and rotate for a benefit (formal repo separation) that matters more at team scale.

**Interview framing:** application CI lives with the application; infrastructure definitions live with infrastructure; the deployment workflow reads infrastructure from a separate repository rather than duplicating manifests — separation of concerns without cross-repo trigger machinery.

**Known limitation, accepted:** a manifest-only change committed to `cloud-platform-lab` (resource limits, ingress annotation, etc.) does not auto-deploy — only a `sarif` push does. `workflow_dispatch` covers manual re-deploys after infra-only changes.

---

## Q2 — GitHub OIDC Terraform placement

**Decision:** split by what each resource actually depends on.

- **Persistent** (`environments/dev/github-actions`): OIDC provider, IAM role, IAM policy (ECR push + `eks:DescribeCluster`).
- **Ephemeral** (`eks-platform`): EKS access entry, EKS access policy association — both reference `cluster_name` directly and cannot exist independent of a live cluster.

**Rationale:** the IAM identity is durable. What that identity is allowed to do inside a specific cluster is not — it's recreated by the same mechanism that already recreates the LBC and EBS CSI IRSA wiring in `eks-platform` each cycle.

---

## Q3 — Behavior when EKS is intentionally torn down

**Decision:** three-way trigger split.

- **Pull request:** checkout → `npm ci` → test → audit → build. No AWS credentials requested at all — PR runs never assume the deploy role.
- **Push to `main`:** build → push image → check cluster existence → deploy if present, skip successfully with a clear message if absent.
- **`workflow_dispatch`:** manual deploy, used whenever the cluster is intentionally brought back up (also covers the Q1 manifest-only-change case).

### Publish-time ECR existence check (implementation requirement)

Every Publish run — `push` and `workflow_dispatch` alike — checks ECR first for the full-SHA tag and reuses the existing image if that tag already exists; it builds and pushes only when the image is absent. This is a deliberate broadening of the original design, which ran the check only under `workflow_dispatch`: running it unconditionally makes same-SHA reruns of a `push` idempotent and compatible with immutable ECR tags, at no cost to the `push` path — a new commit's full-SHA tag never pre-exists, so it still builds and publishes automatically. It also still covers manifest-only redeployments via `workflow_dispatch` without overwriting immutable tags or rebuilding unchanged application code.

This means the Publish job's build/push steps (Q4, steps 6–8) are conditional on an ECR existence check for every trigger, not `push`-unconditional as originally decided.

### Exact cluster-absent error handling (implementation requirement)

The preflight step must capture the actual error from `aws eks describe-cluster`, not rely on a blanket `continue-on-error: true` at the step level — that would swallow every failure mode identically, including ones that should fail loudly.

- `ResourceNotFoundException` → expected state (cluster intentionally torn down) → skip the deploy job, exit 0, clear log message.
- `AccessDeniedException` → real problem (broken trust policy, missing permission, revoked role) → fail the workflow.
- Any other error (throttling, network, malformed call, etc.) → fail the workflow.

This requires explicit branching on the captured stderr/exit code in the shell step — capture output, grep for `ResourceNotFoundException` specifically, exit 0 only on that match — not GitHub Actions' `continue-on-error`, which cannot distinguish between these cases.

---

## Q4 — Pipeline structure (job boundaries)

**Validation** (no AWS credentials; runs on PR and push):
1. Checkout `sarif`
2. `npm ci`
3. `npm test`
4. `npm audit --omit=dev`
5. `npm run build`

**Publish** (push to `main`, or `workflow_dispatch`; requests OIDC token):
6. OIDC login (`aws-actions/configure-aws-credentials`)
7. Build `linux/amd64` image
8. Push to ECR, tagged with the full 40-character `github.sha`

*Steps 6–8 run only if that SHA's image doesn't already exist in ECR — for every Publish trigger, not only `workflow_dispatch` — see Q3.*

**Deploy** (push to `main`, gated on cluster presence; `workflow_dispatch` always runs it):
9. Check cluster exists (see Q3 error handling)
10. Checkout `cloud-platform-lab`
11. `kustomize edit set image` to the just-pushed tag
12. Apply the `eks` overlay
13. `kubectl rollout status deployment/sarif -n sarif`
14. Verify the running image matches the pushed SHA
15. Verify `/api/health`

Only Publish and Deploy ever request AWS credentials. Validation runs identically on every push and PR without any AWS exposure — a security property worth stating explicitly, not just a pipeline detail.

---

## Q5 — Image tagging

**Decision:** CI-built images are tagged with the full 40-character `github.sha` — not the short SHA, not `latest`.

- `github.sha` is available in workflow context with no extra computation and carries no truncation collision risk.
- The existing image (`sarif:5012516`, short-SHA, pushed manually during Phase 1C) remains as historical evidence of the Phase 1C verification pass. It is not touched or re-tagged. CI-built images use the full-SHA convention going forward; the two naming conventions are not reconciled retroactively.

**Overlay update strategy:** patch the image reference during CI (`kustomize edit set image`) without committing the tag back into `cloud-platform-lab`. See Q6 for the tradeoff this creates.

---

## Q6 — CI/CD vs. GitOps (explicit tradeoff)

**Decision:** this is CI/CD, not GitOps — an intentional, defensible choice for Phase 1D, not an oversight.

- Git stores deployment *structure* (manifests, overlay, kustomization).
- ECR stores immutable *artifacts* (SHA-tagged images).
- Kubernetes stores which artifact is *currently running* — this state is not mirrored back into git.

**Consequence to be able to explain in an interview:** a clean checkout of `cloud-platform-lab` does not tell you the exact image currently deployed. The live image reference is stored in the Kubernetes Deployment, while ECR stores the corresponding immutable artifact and digest. Git intentionally does not mirror that runtime image selection:

```
kubectl get deployment sarif -n sarif \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Full GitOps (Argo CD Image Updater, Flux) would commit the running tag back to git so the repo always mirrors cluster state. That's deliberately out of scope here, and is legitimate future work (Phase 1E/1F), not a gap being hidden.

---

## Q7 — Kubernetes authentication for the GitHub Actions role

**Decision:** `aws_eks_access_entry` + `aws_eks_access_policy_association`, using `AmazonEKSEditPolicy` scoped to `access_scope { type = "namespace", namespaces = ["sarif"] }`. Both resources live in `eks-platform`, alongside the existing LBC and EBS CSI IRSA wiring.

**Explicitly ruled out:**
- **`aws-auth` ConfigMap** — not applicable. The cluster already uses `authentication_mode = "API"`; there is no ConfigMap-based auth path on this cluster.
- **IRSA** — wrong direction. IRSA lets a pod *inside* the cluster assume an AWS IAM role. The GitHub Actions role is an *external* IAM principal that needs Kubernetes RBAC permissions — access entries are the mechanism for that, not IRSA.

**Accepted MVP limitation:** `AmazonEKSEditPolicy` is namespace-scoped but broader than a custom deployment-specific RBAC policy. It may authorize operations the workflow never performs. Phase 1D intentionally uses the AWS-managed policy as a pragmatic baseline; custom deployment-specific Kubernetes RBAC is future hardening work, not implemented here. This is namespace-scoped least-*damage*, not least-privilege — worth being precise about the difference if asked.

---

## Q8 — Namespace ownership

**Decision:** `eks-platform` owns `namespace/sarif` for EKS going forward. The EKS CI deployment path must not manage the Namespace object.

**Why this isn't free:** `k8s/base/kustomization.yaml` currently lists `namespace.yaml` in its `resources:`, so `kubectl apply -k` already creates the Namespace today. Moving ownership to Terraform without changing this creates dual ownership: Terraform's `eks-platform` stack and Kustomize would both assert the Namespace object, and any label drift between the two (the current `namespace.yaml` sets `app.kubernetes.io/name: sarif` and `app.kubernetes.io/part-of: sarif`) would show up as perpetual `terraform plan` diff noise.

**Resolution: Option 2, implemented as a file move (not a same-file reference).**
- Move `k8s/base/namespace.yaml` to `k8s/overlays/local/namespace.yaml` and remove it from `k8s/base/kustomization.yaml`'s `resources:`.
- List it as a resource directly in `k8s/overlays/local/kustomization.yaml`, so local/kind development stays one-command with no separate manual apply step.
- Omit it from `k8s/overlays/eks/kustomization.yaml`, so `eks-platform`'s Terraform-managed Namespace has sole ownership on EKS — no dual-ownership drift.

**Correction from the original planning pass:** the `secret.example.yaml` precedent cited below only shows the pattern of *excluding* a resource from `base`'s `resources:` list while still committing the file — it does not mean the file can stay physically in `base/` and be referenced from another overlay. Kustomize's default load restrictor (`LoadRestrictionsRootOnly`) forbids an overlay from listing a resource file that lives outside its own root, so `k8s/overlays/local/kustomization.yaml` cannot reference `../../base/namespace.yaml`. The manifest must physically live inside the overlay that uses it. This is why the resolution above is a `git mv`, not just a `kustomization.yaml` edit — and matches this document's own completion criteria (namespace.yaml "present only in `k8s/overlays/local`").

Precedent already exists in this repo for excluding a resource from `base` deliberately and documenting why: `secret.example.yaml` is committed but intentionally not listed in `kustomization.yaml`'s `resources:`, with a comment explaining the reasoning. The same *exclusion* pattern applies to `base`'s kustomization here — the difference is that the namespace manifest itself relocates with it, since (unlike the secret template) it needs to actually be applied somewhere.

**Implemented in Phase 1D Increment 4 (implementation step 7).**

---

## Q9 — Secret and PVC ownership

**Secrets:**
- Provisioned separately, out-of-band — already true today. `secret.example.yaml` is a template only; real secrets are applied manually via `kubectl create secret generic` with an explicit key allowlist.
- CI does not create, recreate, or manage secret values at any point.

**PVC:**
- Created by the committed manifest (`k8s/base/pvc.yaml`), same as today.
- Routine CI deploys simply reapply the existing manifest (`kubectl apply -k`) — idempotent, since PVC spec fields don't change between deploys.
- CI never prunes or deletes the PVC. Teardown remains a deliberate, manual operator action per `TEARDOWN.md`.

No changes required here — this section records that existing discipline extends to the CI pipeline rather than being relaxed by it.

---

## Increment 5 — proven final architecture

Increment 5 implemented and proved the `deploy` job end-to-end, live, twice. One load-bearing discovery during implementation changed the job's `runs-on:` from the original Q4 assumption — documented here as the authoritative as-built architecture.

### Why `deploy` runs on a self-hosted runner, not `ubuntu-latest`

The EKS cluster's public API endpoint is intentionally restricted to a single allowlisted operator IP (`environments/dev/eks/terraform.tfvars`: `endpoint_public_access_cidrs`). GitHub-hosted runners egress from a large, rotating IP pool and can never match that `/32`. Consequence: a GitHub-hosted `deploy` job can complete OIDC (`aws sts get-caller-identity`) and `aws eks update-kubeconfig` — both are AWS control-plane APIs, not gated by the cluster's endpoint CIDR — but every subsequent `kubectl` call to the Kubernetes API server would hang until timeout.

**Decision:** `deploy` runs on a **temporary, repository-level self-hosted GitHub Actions runner** on the operator's Mac, whose network egress already matches the allowlisted IP. This was evaluated against two alternatives and rejected them both, in order to avoid any change to security posture:
- Widen `endpoint_public_access_cidrs` to `0.0.0.0/0` — rejected: reopens the cluster's Kubernetes API to the public internet.
- Allowlist GitHub-hosted runner IP ranges — rejected: that range is large, third-party-controlled, and rotates; it is not a meaningfully narrower exposure than open access.

`validate` and `publish` remain on `ubuntu-latest` — only `deploy` needs to reach the cluster's API server, so only `deploy` needs to run where that reachability exists. No Terraform, IAM, EKS access entry, or endpoint CIDR was changed to make this work.

**Operational model — temporary, not standing infrastructure.** The runner is public-repository-aware risk: `adeagon/sarif` is public, and GitHub explicitly advises against self-hosted runners on public repos, since a job assigned to the runner during a `pull_request` event would execute attacker-controlled checked-out code on the runner's host. This is accepted only as a narrow, time-boxed exception, with controls, not a permanent architecture:
- The configured deploy job does not run on `pull_request` events — its `if:` requires `github.event_name == 'workflow_dispatch'` (see "Steady-state trigger" below) and `github.ref == 'refs/heads/main'`. (Defense-in-depth, not a complete security boundary — see below.)
- Before registering the runner: confirm zero open/queued/approved/running fork-PR workflow runs; temporarily tighten the repo's fork-PR workflow approval to `all_external_contributors` (the strictest available policy).
- The runner is registered and started immediately before a dispatched deployment, kept online only for the duration of that run, then immediately stopped and deregistered (`./config.sh remove`), and the fork-PR approval setting is restored afterward.
- `runs-on: [self-hosted, sarif-deploy]` — a custom label scopes it so no other job in the workflow can land on it by accident.
- `timeout-minutes: 30` bounds any abandoned run.

### Steady-state trigger: `workflow_dispatch` only, not every push

`deploy`'s `if:` condition was corrected after the Increment 5 proof runs. It originally read `github.event_name != 'pull_request' && github.ref == 'refs/heads/main'` — meaning *every* push to `main`, not just the deliberate proof, would queue a `deploy` job. That is a real operational contradiction, distinct from the cluster-absent preflight (below): the only runner able to claim that job (`[self-hosted, sarif-deploy]`) is intentionally deregistered immediately after each use, so an ordinary future push to `main` would queue a `deploy` job with no runner ever available to pick it up.

**Corrected condition:** `if: github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'`. In steady state:
- A push to `main` runs `validate` → `publish` only — the image is built and published, ready to deploy, but nothing deploys automatically.
- Deployment happens only when an operator explicitly triggers `workflow_dispatch` on `main`. A temporary runner must be registered and online *before* that dispatch — since dispatch is a manual, operator-initiated action, the operator controls exactly when the runner needs to exist, rather than the runner needing to be always-on to catch an unpredictable push.

This is separate from the deferred cluster-absent preflight: the preflight question is *what `deploy` should do* when the cluster doesn't exist; this correction is about *when `deploy` should run at all*, given that its only capable runner is deliberately non-persistent.

**Historical evidence unaffected:** the initial deploy run ([29290997161](https://github.com/adeagon/sarif/actions/runs/29290997161)) executed under the original, since-corrected condition, as a deliberate one-time proof that automatic push-triggered deployment works end-to-end while a runner is online. It remains valid evidence of that specific claim — it does not describe the corrected steady-state behavior, which now requires manual dispatch.

### As-built pipeline (differs from the original Q3/Q4 plan)

```
validate  →  ubuntu-latest        (all events: push, pull_request, workflow_dispatch)
publish   →  ubuntu-latest        (push to main / workflow_dispatch; OIDC; idempotent ECR reuse by full-SHA tag)
deploy    →  workflow_dispatch from main only   ([self-hosted, sarif-deploy]; OIDC; temporary runner registered before dispatch)
```

- **OIDC is used by both `publish` and `deploy`** (not deploy alone) — each job independently assumes `arn:aws:iam::702516017596:role/cloud-platform-lab-github-actions` via `aws-actions/configure-aws-credentials`, scoped to only the permissions it needs (`id-token: write` + `contents: read`).
- **Immutable full-`github.sha` image tags** — exactly as decided in Q5; proven with a real 40-character tag end-to-end.
- **Runtime `kustomize edit set image`, never committed back** — the `deploy` job checks out `cloud-platform-lab` at a pinned commit, patches the `eks` overlay's image reference in the ephemeral runner workspace, applies it, and discards the checkout. `cloud-platform-lab` shows zero local diff after every run — confirmed live.
- **Cluster-absent preflight (`aws eks describe-cluster` branching from Q3) was explicitly out of scope for Increment 5** and was not implemented — `deploy` currently assumes the cluster is present. This remains deferred to a later increment (see Completion criteria below).
- **EKS access entry**: namespace-scoped `AmazonEKSEditPolicy` on `sarif` (Q7, unchanged) — proven sufficient for the full `apply` / `rollout status` / `get` sequence used by `deploy`.
- **`sarif` namespace remains Terraform-owned** (Q8, unchanged) — `deploy`'s `kubectl apply -k` never asserts a Namespace object; confirmed by a **clean `terraform -chdir=environments/dev/eks-platform plan`** ("No changes. Your infrastructure matches the configuration.") run immediately after a live deployment, closing out the Q8 completion criterion for real rather than by inspection.
- **Secret handling unchanged (Q9)**: after the namespace/cluster recreation in Increment 4, `sarif-secrets` did not exist. It was recreated **manually, out-of-band**, from the operator's locally gitignored `sarif/app/.env`, using the existing explicit `--from-literal` allowlist process (only `SEATS_API_KEY`, `PUSHOVER_TOKEN`, `PUSHOVER_USER_KEY` required; optional keys included only if present). No value was ever printed, logged, or committed. **`ci.yml` does not create, read, list, or modify Secrets at any point** — this was a one-time operator action, not a CI capability.
- **Runner lifecycle**: registered immediately before the proof, deregistered immediately after (`total_count: 0` confirmed on GitHub afterward) — see "Operational model" above.

### Evidence

- `sarif` commit: `3a3ea27983d38815f9fced71abb88cf2edf81a7d` ("ci: deploy Sarif to EKS")
- Initial deploy run (push-triggered, under the original since-corrected trigger condition — see "Steady-state trigger" above): [run 29290997161](https://github.com/adeagon/sarif/actions/runs/29290997161)
- Same-SHA idempotency run (`workflow_dispatch`): [run 29291839523](https://github.com/adeagon/sarif/actions/runs/29291839523)
- Assumed role (both `publish` and `deploy`): `arn:aws:sts::702516017596:assumed-role/cloud-platform-lab-github-actions/GitHubActions`
- Deployed image: `702516017596.dkr.ecr.us-west-2.amazonaws.com/sarif:3a3ea27983d38815f9fced71abb88cf2edf81a7d` — verified via `kubectl get deployment sarif -n sarif -o jsonpath='{.spec.template.spec.containers[0].image}'` to exactly equal the published tag, both runs.
- Deployment: `READY 1/1`, `AVAILABLE 1`. Pod: `Running`, `1/1` Ready, **0 restarts**.
- PVC `sarif-data`: **Bound**, `gp3`, 1Gi, RWO — same underlying volume (`pvc-cf85018c-e1f8-4fe9-bdcb-ef8cc81b536a`) across both runs, confirming CI never recreates it.
- Ingress/ALB: `k8s-sarif-sarif-443c05ee90-1824879093.us-west-2.elb.amazonaws.com`, `internet-facing`, target `healthy`.
- `GET /api/health` → `200 {"ok":true,"service":"sarif"}`; `GET /` → `200`. Proven on both runs.
- **Idempotency (Run 2, same SHA):** `publish` logged *"Image tag …3a3ea27… already exists in ECR — reusing; skipping build/push"* (build/push steps `skipped`); `deploy`'s `kubectl apply -k` reported **every** resource `unchanged` (`configmap/sarif-config`, `service/sarif`, `persistentvolumeclaim/sarif-data`, `deployment.apps/sarif`, `ingress.networking.k8s.io/sarif`); rollout, image check, and health checks all passed again with no retry needed.

### First-run DNS observation (not an infrastructure defect)

On the initial deploy run, the Kubernetes/AWS portion of the pipeline succeeded completely on the first attempt: OIDC, `kubectl apply -k`, rollout, the running-image check, and the PVC-Bound-on-`gp3` check all passed. Only the final smoke-test step's first attempt failed — `curl` from the self-hosted runner (the operator's Mac) returned `000` (no response) probing `/api/health` for the full retry budget. Direct diagnosis established this was **not** an application, Kubernetes, or AWS problem: the ALB's target group already reported the pod `healthy`, and `curl --resolve` (bypassing DNS) to the ALB's IP directly returned `200` the entire time. The cause was a temporary negative-DNS-cache entry in the operator Mac's local resolver (`mDNSResponder`) for the brand-new ALB hostname — `dig`/`host`, which query nameservers directly, resolved it correctly throughout, while `curl`'s normal resolution path did not. Once that local cache entry cleared (a few minutes later), a retry of only the `deploy` job passed cleanly, and the independent same-SHA `workflow_dispatch` run (Run 2) passed on its first attempt with no retry, confirming the issue was a one-time local caching artifact tied to the ALB's first-ever creation on this recreated cluster — not a recurring or infrastructural condition. No Terraform, IAM, Kubernetes manifest, or application defect was identified.

---

## Implementation sequence

1. Write this design decisions document. *(this document)*
2. Review it against the current repository structure — including deciding the Q8 namespace overlay split (move `namespace.yaml` from `base` to `local`, omit from `eks`). Decision recorded here; implemented in step 7.
3. Commit the planning document.
4. Add the CI validation workflow (test / audit / build only — no AWS credentials; de-risks pipeline shape before adding OIDC complexity).
5. Add persistent GitHub OIDC Terraform (`environments/dev/github-actions`: provider, role, policy).
6. Prove OIDC authentication + ECR push in isolation.
7. Add the ephemeral EKS access entry + access policy association in `eks-platform`, plus implement the namespace-ownership change decided in step 2 (`git mv k8s/base/namespace.yaml` to `k8s/overlays/local/namespace.yaml`).
8. Prove `workflow_dispatch` deployment end-to-end. **Done (Increment 5)** — run [29291839523](https://github.com/adeagon/sarif/actions/runs/29291839523), also serving as the same-SHA idempotency proof.
9. Enable automatic deployment on push to `main`. **Proven once, then corrected (Increment 5)** — run [29290997161](https://github.com/adeagon/sarif/actions/runs/29290997161) deliberately demonstrated this path works end-to-end. It was not kept as steady-state behavior: the runner capable of running `deploy` is temporary and is not on standby for ordinary pushes, so the trigger condition was corrected to `workflow_dispatch`-only immediately afterward (see "Steady-state trigger" above). The cluster-absent preflight mentioned in the original plan for this step was **not** implemented; `deploy` currently assumes the cluster is present (see Completion criteria — deferred).
10. Tear everything down, confirm the preflight skip path fires correctly on a real merge with no cluster present, and document the completed architecture. **Not yet done.** Increment 5 documented the completed *deploy* architecture (this document); the preflight-skip proof and teardown are follow-up work, gated on implementing the deferred cluster-absent preflight first.

---

## Completion criteria

- [x] Push to `main` validates, builds, and publishes — `test` → `audit` → `build` → `push`, proven end-to-end and reconfirmed on every Increment 5 run.
- [x] Automatic push-triggered deployment deliberately proven once — commit `3a3ea27983d38815f9fced71abb88cf2edf81a7d`, run [29290997161](https://github.com/adeagon/sarif/actions/runs/29290997161), documented to the same evidence standard as the Phase 1C teardown/recreate proof. This run executed under `deploy`'s original trigger condition (`!= 'pull_request'`), while the temporary runner happened to be online. That condition has since been corrected to `workflow_dispatch`-only (see "Steady-state trigger" above) — this run remains valid historical evidence that automatic push-triggered deployment works end-to-end; it does not describe current steady-state behavior.
- [x] `workflow_dispatch` deployment and same-SHA idempotency proven — run [29291839523](https://github.com/adeagon/sarif/actions/runs/29291839523): `publish` reused the existing image, every resource `kubectl apply -k` touched reported `unchanged`, rollout and health checks passed with no retry, and the PVC volume was untouched.
- [ ] Cluster-absent preflight and skip behavior: `ResourceNotFoundException` skips cleanly; a simulated `AccessDeniedException` (or other failure) fails the workflow loudly. **Deferred** — not implemented in Increment 5; `deploy` has no cluster-presence preflight yet. Distinct from the trigger-condition correction above: this is about what `deploy` should do when the cluster doesn't exist, not when `deploy` should run. Tracked as follow-up work.
- [x] OIDC authentication working; no static AWS keys in GitHub secrets — proven for **both** `publish` and `deploy` (assumed role `arn:aws:sts::702516017596:assumed-role/cloud-platform-lab-github-actions/GitHubActions`).
- [x] `npm audit --omit=dev` is a hard gate and currently passes clean (0 findings, verified, reconfirmed on every Increment 5 run).
- [x] Images tagged with the full 40-character `github.sha`; `:latest` never used for deploys — verified by direct jsonpath comparison against the running Deployment.
- [x] EKS access entry scoped to `AmazonEKSEditPolicy` / namespace `sarif` — not cluster-admin. Proven sufficient for the full `apply` / `rollout status` / `get` sequence with no RBAC gap.
- [x] Namespace ownership resolved: `namespace.yaml` removed from `k8s/base`, present only in `k8s/overlays/local`, absent from `k8s/overlays/eks` — `eks-platform` has sole ownership on EKS, confirmed by a clean Terraform plan **after a real live deployment**, not just planned: `terraform -chdir=environments/dev/eks-platform plan` → *"No changes. Your infrastructure matches the configuration."*
- [x] Secret and PVC discipline unchanged — CI does not manage Secret values (the post-recreation `sarif-secrets` was restored manually, out-of-band, from `sarif/app/.env`), does not delete or prune the PVC (same volume `pvc-cf85018c-e1f8-4fe9-bdcb-ef8cc81b536a` persisted across both runs), and only reapplies the committed PVC manifest idempotently (`persistentvolumeclaim/sarif-data unchanged` on the second run).
- [x] Pipeline documented: stages, OIDC trust model (why no static keys, and why `deploy` needs a self-hosted runner while the EKS endpoint is `/32`-restricted), image-tagging strategy, and the CI/CD-vs-GitOps tradeoff — see "Increment 5 — proven final architecture" above and `k8s/README.md`.

---

*This document was originally written as planning-only (see the implementation sequence above); it has since been updated in place, increment by increment, to record what was actually built and proven. Everything under "Increment 5 — proven final architecture" and the Completion criteria reflects the live, verified state of the system, not a plan.*
