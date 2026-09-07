provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Environment = "dev"
      ManagedBy   = "Terraform"
      Phase       = "eks-baseline"
      Project     = var.project_name
      Stack       = "dev-eks"
    }
  }
}
