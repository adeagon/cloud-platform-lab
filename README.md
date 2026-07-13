# Cloud Platform Lab

A production-style AWS infrastructure project built with Terraform.

**Built and verified today:** VPC networking (3 AZs), an EKS cluster provisioned via
Terraform, an ECR image registry, a containerized workload (`sarif`) exposed through
an Application Load Balancer with a `gp3` EBS-backed PVC, and a GitHub Actions CI/CD
pipeline (OIDC, no static AWS keys): pushes to `main` validate, build, and publish to ECR;
deployment to EKS is a deliberate `workflow_dispatch` action against a temporary,
purpose-registered runner (automatic push-triggered deployment was proven once, as a
one-time demonstration — see `docs/phase-1d-design.md`).

**Planned for later phases:** cluster-absent deploy preflight, security hardening,
observability, GitOps, and AI/ML model serving. These are future work — not yet
demonstrated in this repo.

## Architecture

```
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
   │     EKS managed node group (worker nodes) + application pods
   │
   └─ Data subnets     10.0.100.0/24  10.0.101.0/24  10.0.102.0/24   (isolated)
         Reserved for RDS / ElastiCache — not yet provisioned

Regional / account-level (outside the VPC):
  ECR       sarif image registry — persists across teardowns
  EKS       cloud-platform-lab-dev — control plane + managed node group
  S3        Terraform remote state backend
  DynamoDB  Terraform state lock table
```

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
│   └── phase-1d-design.md       # Phase 1D CI/CD design decisions + Increment 5 evidence
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

## Phases

- **Phase 1A — Kubernetes fundamentals on kind:** ✅ complete
- **Phase 1B — Sarif on local Kubernetes via Kustomize:** ✅ complete
- **Phase 1C — EKS via Terraform (ECR, ALB, `gp3` PVC, Pushover, teardown/recreate):** ✅ complete
- **Phase 1D — GitHub Actions / CI/CD deployment automation:** ✅ core pipeline complete (OIDC → ECR → EKS deploy, proven live twice); cluster-absent deploy preflight deferred
- **Future — cluster-absent preflight, security hardening, observability, GitOps, AI/ML model serving**

## Current status

Phase 1C is complete, and Phase 1D's core CI/CD pipeline is implemented and proven live
against the running stack (cluster currently up, pending teardown approval):

- ✅ EKS cluster provisioned via Terraform (`environments/dev/eks`)
- ✅ GitHub Actions CI/CD: push to `main` runs validate → publish (OIDC → ECR, idempotent
  full-SHA tags); deploy (OIDC → EKS) is `workflow_dispatch`-only in steady state, proven
  live plus an independent same-SHA idempotency rerun. Automatic push-triggered deployment
  was also deliberately proven once, as historical evidence, under a trigger condition since
  corrected — see `docs/phase-1d-design.md` ("Steady-state trigger")
- ✅ ECR image `sarif:3a3ea27983d38815f9fced71abb88cf2edf81a7d` deployed via CI and verified
- ✅ Application reachable through an ALB (HTTP-only for this phase — no TLS/domain yet)
- ✅ `gp3` PVC (EBS CSI) bound; backing EBS volume provisioned and reclaimed on teardown
- ✅ Pushover notification path verified from inside the pod
- ✅ Full teardown → recreate → re-verify → teardown cycle proven (Phase 1C)
- ⏭️ Cluster-absent deploy preflight deferred to a follow-up increment

See [`docs/phase-1c-completion.md`](docs/phase-1c-completion.md) and
[`docs/phase-1d-design.md`](docs/phase-1d-design.md) for the full evidence.

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
