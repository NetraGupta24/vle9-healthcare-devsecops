# Step 1 - Secure infrastructure on AWS (Terraform).
# Run from your laptop as your own IAM user (never the root account).
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # State stays local (infra/terraform/terraform.tfstate, git-ignored).
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "vle9-healthcare-devsecops"
      ManagedBy = "terraform"
      DataClass = "synthetic-phi"
    }
  }
}
