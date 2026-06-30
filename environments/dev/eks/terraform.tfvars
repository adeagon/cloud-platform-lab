aws_region         = "us-west-2"
environment        = "dev"
project_name       = "cloud-platform-lab"
cluster_name       = "cloud-platform-lab-dev"
kubernetes_version = "1.34"

# Set this to your current public IP before running terraform apply.
# Fetch with: curl -s https://checkip.amazonaws.com
# If your ISP/home IP changes, update this value and re-apply before using kubectl.
endpoint_public_access_cidrs = ["64.98.210.28/32"]
