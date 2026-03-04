# Cloud Platform Lab

A production-style AWS infrastructure project built with Terraform, demonstrating
VPC networking, EKS (Kubernetes), GitOps deployment, observability, and AI/ML
serving infrastructure.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  AWS Account (us-west-2)                                        │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  VPC: 10.0.0.0/16                                        │  │
│  │                                                           │  │
│  │  ┌─────────────────────┐  ┌─────────────────────┐        │  │
│  │  │  AZ: us-west-2a     │  │  AZ: us-west-2b     │        │  │
│  │  │                     │  │                     │        │  │
│  │  │  Public: 10.0.1.0/24│  │  Public: 10.0.2.0/24│        │  │
│  │  │  (NAT GW, ALB)      │  │  (ALB)              │        │  │
│  │  │                     │  │                     │        │  │
│  │  │  Private:10.0.10.0/24  │  Private:10.0.20.0/24│       │  │
│  │  │  (EKS nodes, apps)  │  │  (EKS nodes, apps)  │        │  │
│  │  │                     │  │                     │        │  │
│  │  │  Data: 10.0.100.0/24│  │  Data: 10.0.200.0/24│        │  │
│  │  │  (RDS, ElastiCache)  │  │  (RDS, ElastiCache) │        │  │
│  │  └─────────────────────┘  └─────────────────────┘        │  │
│  │                                                           │  │
│  │  Internet Gateway ──► Public Route Table                  │  │
│  │  NAT Gateway ──► Private Route Table                      │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                 │
│  S3 Bucket: terraform state (remote backend)                    │
│  DynamoDB Table: terraform state lock                           │
└─────────────────────────────────────────────────────────────────┘
```

## Project Structure

```
cloud-platform-lab/
├── README.md
├── environments/
│   └── dev/
│       ├── main.tf              # Root module — calls child modules
│       ├── variables.tf         # Input variables for dev environment
│       ├── outputs.tf           # Outputs (VPC ID, subnet IDs, etc.)
│       ├── terraform.tfvars     # Dev-specific values
│       ├── providers.tf         # AWS provider + backend config
│       └── versions.tf          # Required providers and versions
└── modules/
    └── networking/
        ├── main.tf              # VPC, subnets, route tables, NAT/IGW
        ├── variables.tf         # Module inputs
        └── outputs.tf           # Module outputs
```

## Phases

- **Phase 1 (Weeks 1-4):** VPC, networking, remote state, RDS ← *you are here*
- **Phase 2 (Weeks 5-8):** EKS cluster, node groups, CI/CD for Terraform
- **Phase 3 (Weeks 9-12):** Kubernetes workloads, ArgoCD/GitOps, observability
- **Phase 4 (Weeks 13-16):** AI/ML serving (vLLM on K8s), model monitoring

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

## Cost Estimate (Dev Environment)

| Resource        | Estimated Monthly Cost |
|-----------------|----------------------|
| NAT Gateway     | ~$32 + data transfer |
| VPC             | Free                 |
| Subnets         | Free                 |
| S3 (state)      | < $1                 |
| DynamoDB (lock) | < $1                 |
| **Total (networking only)** | **~$33/mo** |

> **Tip:** The NAT Gateway is the main cost driver. Destroy with `terraform destroy`
> when not actively working to save money.
