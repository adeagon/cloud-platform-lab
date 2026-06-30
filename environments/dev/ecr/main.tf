########################################
# ECR Repository — sarif
########################################
# Persistent across EKS and networking teardowns so Phase 1D GitHub Actions
# can push images at any time without first applying the eks stack.
# Name matches the k8s/overlays/eks stub reference:
#   <account>.dkr.ecr.<region>.amazonaws.com/sarif
#
# guard: prevent_destroy + force_delete = false means images are protected;
# remove these guards manually before any intentional full teardown.

resource "aws_ecr_repository" "sarif" {
  name                 = "sarif"
  image_tag_mutability = "MUTABLE"
  force_delete         = false # safety: don't nuke pushed images on destroy

  image_scanning_configuration {
    scan_on_push = true # basic hygiene; not a supply-chain gate
  }

  tags = {
    Name = "sarif"
  }

  lifecycle {
    prevent_destroy = true
  }
}

########################################
# Lifecycle Policy — keep last 20 images
########################################
resource "aws_ecr_lifecycle_policy" "sarif" {
  repository = aws_ecr_repository.sarif.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire images beyond the 20 most recent"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 20
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
