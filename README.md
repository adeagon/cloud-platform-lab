# Cloud Platform Lab

A production-style AWS platform, built with Terraform, that provisions and operates the
infrastructure for [**Sarif**](https://github.com/adeagon/sarif) — a containerized Node.js
application — using Amazon EKS, Kubernetes, GitHub Actions, GitHub OIDC, Amazon ECR, the AWS
Load Balancer Controller, and EBS-backed persistent storage.

The full system was deployed to AWS and verified end-to-end: networking, an EKS cluster,
platform components (Load Balancer Controller, EBS CSI), and Sarif itself, built, published,
and deployed through a GitHub Actions pipeline authenticating via OIDC. The ephemeral EKS,
networking, and application infrastructure was then torn down cleanly from committed code —
the GitHub Actions CI/CD identity (OIDC provider, IAM role/policy), the ECR repository and
published images, and the Terraform remote-state backend remain in place.

## What this project demonstrates

- Production-style Infrastructure as Code with Terraform
- A multi-stack Terraform architecture (networking, EKS, platform components, ECR, GitHub
  OIDC) with S3/DynamoDB remote state
- EKS cluster provisioning and full lifecycle management — created, operated, and destroyed
- Kubernetes application deployment via Kustomize (base + overlays)
- GitHub Actions CI/CD, from validation through build to deployment
- GitHub OIDC authentication — no static AWS keys stored in GitHub Actions or GitHub secrets
- Immutable, full-SHA image tagging in ECR with idempotent existence checks
- ALB ingress via the AWS Load Balancer Controller
- EBS CSI-backed `gp3` persistent storage
- A controlled teardown and recreate cycle, verified end-to-end
- Explicit separation of persistent and ephemeral infrastructure by lifecycle

## Platform and application

This repository is the **platform**: Terraform-managed AWS infrastructure, Kubernetes
manifests, IAM/OIDC identity, networking, storage, and the deployment architecture that runs
on top of it. [**Sarif**](https://github.com/adeagon/sarif) is the **application** — a real
flight-award search, monitoring, and alerting service built with Node.js/Express and a web
frontend, using SQLite for persistence, live award-availability data from Seats.aero,
scheduled background monitoring, SSE-based browser alerts, and Pushover push notifications.

- `cloud-platform-lab` (this repo) owns Terraform, AWS infrastructure, Kubernetes manifests,
  IAM/OIDC, platform components, networking, storage, and deployment architecture.
- [`sarif`](https://github.com/adeagon/sarif) owns the application code, tests, Docker image,
  and application-side GitHub Actions workflow.
- GitHub Actions builds and tests Sarif, publishes immutable images to ECR, and deploys them
  onto EKS provisioned by this repository.

Together, the two repositories demonstrate an end-to-end platform delivery path —
provisioning, identity, build, publish, deploy, and verification — for a real application,
not a toy `hello-world` workload.

## Related repositories

| Repository | Purpose |
|---|---|
| [`cloud-platform-lab`](https://github.com/adeagon/cloud-platform-lab) | AWS infrastructure, Terraform, Kubernetes platform, CI/CD identity, networking, storage, and deployment architecture |
| [`sarif`](https://github.com/adeagon/sarif) | Flight-award monitoring application built, tested, published, and deployed by this platform |

## Architecture

### Delivery pipeline

```text
Developer
  → GitHub (sarif repo)
  → GitHub Actions
      → validate   (test, audit, build)
      → publish    (OIDC → ECR, immutable full-SHA tag)
      → deploy     (OIDC → EKS, temporary self-hosted runner)
  → EKS (Kubernetes: Deployment, Service, Ingress)
  → AWS Load Balancer Controller → ALB
  → Sarif (running application)
```

Steady-state triggers:
- `pull_request` → `validate` only — no AWS credentials requested
- push to `main` → `validate` + `publish` (image built and pushed to ECR)
- `workflow_dispatch` from `main` → `validate` + `publish` (or reuse the existing image) +
  `deploy`
- `deploy` runs on a temporary, purpose-registered self-hosted runner — the EKS API endpoint
  is restricted to a single allowlisted IP
- No static AWS keys are stored in GitHub Actions or GitHub secrets — the `publish` and
  `deploy` jobs obtain short-lived AWS credentials through GitHub OIDC

### AWS infrastructure

```text
AWS Account (us-west-2)
│
└─ VPC 10.0.0.0/16
   │
   ├─ Availability Zones: us-west-2a, us-west-2b, us-west-2c
   │
   ├─ Public subnets   10.0.1.0/24    10.0.2.0/24    10.0.3.0/24     → Internet Gateway
   │     NAT Gateway (in a public subnet) + Application Load Balancer
   │
   ├─ Private subnets  10.0.16.0/20   10.0.32.0/20   10.0.48.0/20    → NAT Gateway
   │     EKS managed node group (worker nodes) + Sarif application pods
   │
   └─ Data subnets     10.0.100.0/24  10.0.101.0/24  10.0.102.0/24   (isolated)
         Reserved for RDS / ElastiCache — not yet provisioned

Regional / account-level (outside the VPC):
  ECR       sarif image registry — persists across teardowns
  EKS       cloud-platform-lab-dev — control plane + managed node group
  S3        Terraform remote state backend
  DynamoDB  Terraform state lock table
```

## Technical accomplishments

- A reusable Terraform networking module (VPC, subnets across 3 AZs, NAT/IGW, route tables)
- Persistent and ephemeral infrastructure separated into independent Terraform stacks
- S3 remote state with DynamoDB state locking
- An EKS managed node group plus platform add-ons, with EBS CSI and the AWS Load Balancer
  Controller receiving scoped AWS permissions through IRSA
- Namespace-scoped EKS access for CI through `AmazonEKSEditPolicy` — not cluster-admin
- A GitHub OIDC trust policy pinned to the exact subject
  `repo:adeagon/sarif:ref:refs/heads/main`
- Immutable, full-SHA (`github.sha`) image tags in ECR — never `latest`
- A typed ECR image-existence check that makes same-SHA CI reruns idempotent
- Runtime Kustomize image injection (`kustomize edit set image`) without committing
  deployment state back to git
- Terraform ownership of the EKS namespace, with a clean post-deploy `terraform plan`
  proving no ownership drift against Kustomize
- A teardown order that lets the ALB and EBS volume finalize before their controllers are
  torn down
- A full infrastructure teardown → recreate → re-verify → teardown cycle proven in Phase 1C,
  followed by an initial CI deployment and an independent same-SHA idempotency deployment
  proof in Phase 1D

## Phases

- **Phase 1A — Kubernetes fundamentals on kind:** ✅ complete
- **Phase 1B — Sarif on local Kubernetes via Kustomize:** ✅ complete
- **Phase 1C — EKS via Terraform (ECR, ALB, `gp3` PVC, Pushover, teardown/recreate):** ✅ complete
- **Phase 1D — GitHub Actions / CI/CD deployment automation:** ✅ core pipeline complete (OIDC → ECR → EKS deploy, proven live twice); cluster-absent deploy preflight deferred
- **Future — cluster-absent preflight, security hardening, observability, GitOps, AI/ML model serving**

## Current status

Phase 1C is complete, and Phase 1D's core CI/CD pipeline successfully deployed and operated
Sarif on EKS before the ephemeral infrastructure was torn down cleanly:

- ✅ EKS cluster was provisioned via Terraform (`environments/dev/eks`), proven live, and
  torn down in the controlled teardown documented in `docs/phase-1d-completion.md`
- ✅ GitHub Actions CI/CD: push to `main` runs validate → publish (OIDC → ECR, idempotent
  full-SHA tags); deploy (OIDC → EKS) is `workflow_dispatch`-only in steady state. Automatic
  push-triggered deployment was proven once, historically, under a trigger condition since
  corrected to manual `workflow_dispatch` — see `docs/phase-1d-design.md` ("Steady-state
  trigger")
- ✅ Sarif was deployed to EKS through GitHub Actions; the exact full-SHA image
  (`sarif:3a3ea27983d38815f9fced71abb88cf2edf81a7d`) was verified on the running Deployment
- ✅ `/api/health` and `/` both returned HTTP 200 through the ALB
- ✅ The PVC was `Bound` on `gp3`
- ✅ The same-SHA rerun reused the ECR image and reapplied Kubernetes resources unchanged
- ✅ Pushover notification path verified from inside the pod
- ✅ The ephemeral infrastructure was then torn down cleanly; ECR images and persistent
  CI/CD/backend resources remain
- ✅ Full teardown → recreate → re-verify → teardown cycle proven (Phase 1C)
- ⏭️ Cluster-absent deploy preflight deferred to a follow-up increment

See [`docs/phase-1c-completion.md`](docs/phase-1c-completion.md),
[`docs/phase-1d-design.md`](docs/phase-1d-design.md), and
[`docs/phase-1d-completion.md`](docs/phase-1d-completion.md) for the full evidence.

## Repository organization

- **`environments/`** — Terraform root and per-stack configurations (networking, ECR, EKS,
  EKS platform components, GitHub OIDC/IAM) for the `dev` environment.
- **`modules/`** — Reusable Terraform modules (currently networking: VPC, subnets, routing)
  shared across environments.
- **`k8s/`** — Kustomize base and overlays for deploying Sarif to local (`kind`) and EKS
  clusters; see [`k8s/README.md`](k8s/README.md) for the full design rationale and local
  bring-up runbook.
- **`docs/`** — Phase-by-phase design decisions and completion/evidence records.
- **`kind/`** — Local Kubernetes cluster configuration for offline development against
  `k8s/overlays/local`.
- **`k8s-fundamentals/`** — Standalone Kubernetes learning exercises, unrelated to the Sarif
  deployment path.

## Project Structure

```
cloud-platform-lab/
├── README.md
├── kind/
│   └── cluster.yaml             # Local kind cluster (extraPortMappings 80/443 for nginx ingress)
├── environments/
│   └── dev/
│       ├── main.tf              # Networking module + remote-state (S3 bucket, DynamoDB lock)
│       ├── variables.tf         # Input variables for dev environment
│       ├── outputs.tf           # Outputs (VPC ID, subnet IDs, etc.)
│       ├── terraform.tfvars     # 3-AZ VPC + subnet CIDRs
│       ├── providers.tf         # AWS provider + backend config
│       ├── versions.tf          # Required providers and versions
│       ├── ecr/                 # ECR repo for the sarif image (persists across teardowns)
│       ├── eks/                 # EKS cluster, managed node group, IAM/OIDC, KMS, core add-ons
│       ├── eks-platform/        # EBS CSI, gp3 default StorageClass, AWS Load Balancer Controller (IRSA),
│       │                        # Terraform-owned sarif namespace, GitHub Actions EKS access entry
│       └── github-actions/      # Persistent GitHub OIDC provider + IAM role/policy for CI/CD (Phase 1D)
├── modules/
│   └── networking/
│       ├── main.tf              # VPC, subnets, route tables, NAT/IGW
│       ├── variables.tf         # Module inputs
│       └── outputs.tf           # Module outputs
├── docs/
│   ├── phase-1c-completion.md   # Phase 1C evidence + teardown/recreate proof
│   ├── phase-1d-design.md       # Phase 1D CI/CD design decisions + Increment 5 evidence
│   └── phase-1d-completion.md   # Phase 1D evidence, teardown verification, deferred work
├── TEARDOWN.md                  # Teardown order + cost cleanup checklist
├── k8s/
│   ├── README.md                # Design rationale + local bring-up runbook (interview-ready)
│   ├── base/                    # Kustomize base — app-agnostic defaults
│   │   ├── kustomization.yaml
│   │   ├── configmap.yaml       # Non-secret env vars
│   │   ├── secret.example.yaml  # TEMPLATE only — real secret applied out-of-band
│   │   ├── pvc.yaml             # SQLite persistence (ReadWriteOnce, 1Gi)
│   │   ├── deployment.yaml      # replicas:1, Recreate strategy, probes
│   │   ├── service.yaml         # ClusterIP :3001
│   │   └── ingress.yaml         # No host/class in base (overlays add these)
│   └── overlays/
│       ├── local/               # nginx ingress, sarif.local host, local image tag
│       │   ├── namespace.yaml             # local/kind only — EKS namespace is Terraform-managed
│       │   ├── configmap-cors-patch.yaml  # CORS_ORIGIN: http://sarif.local
│       │   └── ingress-patch.yaml         # ingressClassName: nginx, host: sarif.local
│       └── eks/                 # ALB + ECR image — deployed and verified in Phase 1C
│           ├── kustomization.yaml         # images newTag:5012516; ingress-patch
│           └── ingress-patch.yaml         # ingressClassName: alb, internet-facing
└── k8s-fundamentals/
    ├── k8s-learning-notes.md    # K8s concepts reference
    └── manifests/               # Exercise manifests (Exercises 1-7)
```

## Prerequisites

- AWS account with IAM user configured
- AWS CLI v2 installed and configured (`aws configure`)
- Terraform >= 1.14 installed (`terraform version`)
- Git

## Getting Started

```bash
# 1. Clone this repo
git clone <your-repo-url>
cd cloud-platform-lab

# 2. Set up remote state (one-time)
cd environments/dev
# First apply with local state to create the S3 bucket and DynamoDB table,
# then migrate to remote backend. See comments in providers.tf.

# 3. Initialize Terraform
terraform init

# 4. Review the plan
terraform plan

# 5. Apply
terraform apply
```

The EKS stacks (`environments/dev/eks`, then `environments/dev/eks-platform`) are applied
after networking. See [`docs/phase-1c-completion.md`](docs/phase-1c-completion.md) for the
full apply/verify sequence and [`TEARDOWN.md`](TEARDOWN.md) for the teardown order.

## Cost & cleanup

Order-of-magnitude only — actual cost depends on region, instance types, and data transfer.
These are rough figures for reasoning about the main drivers, **not** an authoritative bill.

| Resource (while running)          | Rough order of magnitude              |
|-----------------------------------|---------------------------------------|
| EKS control plane                 | tens of $/mo (per-cluster hourly)     |
| Worker nodes (managed node group) | depends on instance type × count      |
| NAT Gateway                       | tens of $/mo + data transfer          |
| Application Load Balancer         | low tens of $/mo + LCU/data           |
| EBS `gp3` volume(s)               | a few $/mo                            |
| S3 state + DynamoDB lock          | pennies/mo                            |
| VPC / subnets / IGW               | free                                  |

> **Cleanup is your responsibility.** The EKS control plane, worker nodes, NAT Gateway, ALB,
> EBS volumes, and Elastic IPs all bill while running — tear them down when not actively
> working. Follow [`TEARDOWN.md`](TEARDOWN.md) for the exact order and the final AWS
> verification checks. The ECR `sarif` repo + image and the S3/DynamoDB state backend are
> intentionally retained across teardowns.
