terraform {
  required_version = ">= 1.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # isolated to this stack; environments/dev stays on ~> 5.0
    }
  }
}
