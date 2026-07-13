# Phase 1D — GitHub Actions CI/CD Design Decisions

**Status:** Planning only. No Terraform, Kubernetes manifests, GitHub Actions workflows, or application code have been changed to produce this document. No AWS resources were created.

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

**Resolution: Option 2.**
- Remove `namespace.yaml` from `k8s/base/kustomization.yaml`'s `resources:`.
- Add it explicitly as a resource in `k8s/overlays/local/kustomization.yaml`, so local/kind development stays one-command with no separate manual apply step.
- Omit it from `k8s/overlays/eks/kustomization.yaml`, so `eks-platform`'s Terraform-managed Namespace has sole ownership on EKS — no dual-ownership drift.

Precedent already exists in this repo for excluding a resource from `base` deliberately and documenting why: `secret.example.yaml` is committed but intentionally not listed in `kustomization.yaml`'s `resources:`, with a comment explaining the reasoning. The same pattern applies here.

**Architecturally decided; not yet implemented.** This planning pass records the decision — actually editing `k8s/base/kustomization.yaml`, `k8s/overlays/local/kustomization.yaml`, and `k8s/overlays/eks/kustomization.yaml` happens in implementation step 2 below, not here.

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

## Implementation sequence

1. Write this design decisions document. *(this document)*
2. Review it against the current repository structure — including implementing the Q8 namespace overlay split (remove `namespace.yaml` from `base`, add to `local`, omit from `eks`).
3. Commit the planning document.
4. Add the CI validation workflow (test / audit / build only — no AWS credentials; de-risks pipeline shape before adding OIDC complexity).
5. Add persistent GitHub OIDC Terraform (`environments/dev/github-actions`: provider, role, policy).
6. Prove OIDC authentication + ECR push in isolation.
7. Add the ephemeral EKS access entry + access policy association in `eks-platform`, plus the resolved namespace-ownership change from step 2.
8. Prove `workflow_dispatch` deployment end-to-end.
9. Enable automatic deployment on push to `main`, with the cluster-absent preflight in place.
10. Tear everything down, confirm the preflight skip path fires correctly on a real merge with no cluster present, and document the completed architecture.

---

## Completion criteria

- [ ] Push to `main` runs test → audit → build → push → (deploy if cluster present, clean skip if not).
- [ ] OIDC authentication working; no static AWS keys in GitHub secrets.
- [ ] `npm audit --omit=dev` is a hard gate and currently passes clean (0 findings, verified).
- [ ] Images tagged with the full 40-character `github.sha`; `:latest` never used for deploys.
- [ ] Cluster-absent path tested for real: `ResourceNotFoundException` skips cleanly; a simulated `AccessDeniedException` (or other failure) fails the workflow loudly.
- [ ] At least one deliberate automatic deploy on merge to `main`, proven while the stack is up, documented with evidence (same standard as the Phase 1C teardown/recreate proof).
- [ ] EKS access entry scoped to `AmazonEKSEditPolicy` / namespace `sarif` — not cluster-admin.
- [ ] Namespace ownership resolved: `namespace.yaml` removed from `k8s/base`, present only in `k8s/overlays/local`, absent from `k8s/overlays/eks` — `eks-platform` has sole ownership on EKS, confirmed by a clean Terraform plan after deployment, not just planned.
- [ ] Secret and PVC discipline unchanged — CI does not manage Secret values, does not delete or prune the PVC, and only reapplies the committed PVC manifest idempotently.
- [ ] Pipeline documented in `sarif`'s README: stages, OIDC trust model (why no static keys), image-tagging strategy, and the CI/CD-vs-GitOps tradeoff.

---

*No Terraform, Kubernetes manifests, GitHub Actions workflows, or application code were modified to produce this document. No AWS resources were created.*
