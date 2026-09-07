variable "cloudfront_distribution_arn" {
  type        = string
  description = "ARN of the only CloudFront distribution that the frontend deployer may invalidate."

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:cloudfront::[0-9]{12}:distribution/[A-Z0-9]+$", var.cloudfront_distribution_arn))
    error_message = "cloudfront_distribution_arn must be a valid CloudFront distribution ARN without a wildcard."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment used by the IAM role and GitHub Environment subject."

  validation {
    condition     = can(regex("^[a-z0-9]+(?:[-_][a-z0-9]+)*$", var.environment))
    error_message = "environment must use lowercase letters, numbers, hyphens or underscores."
  }
}

variable "frontend_bucket_arn" {
  type        = string
  description = "ARN of the only private S3 bucket that receives static frontend releases."

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:s3:::[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.frontend_bucket_arn))
    error_message = "frontend_bucket_arn must be a valid S3 bucket ARN without an object path or wildcard."
  }
}

variable "github_oidc_provider_arn" {
  type        = string
  description = "Existing account-level GitHub Actions OIDC provider ARN."

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "github_oidc_provider_arn must reference token.actions.githubusercontent.com."
  }
}

variable "github_organization" {
  type        = string
  description = "GitHub organization that owns the trusted repository."

  validation {
    condition     = can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", var.github_organization))
    error_message = "github_organization must be a valid GitHub organization name."
  }
}

variable "github_owner_id" {
  type        = number
  description = "Immutable numeric ID of the GitHub account that owns the trusted repository."

  validation {
    condition     = var.github_owner_id > 0 && floor(var.github_owner_id) == var.github_owner_id
    error_message = "github_owner_id must be a positive integer."
  }
}

variable "github_repository" {
  type        = string
  description = "GitHub repository whose Environment may assume the frontend deployer role."

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be a valid GitHub repository name."
  }
}

variable "github_repository_id" {
  type        = number
  description = "Immutable numeric ID of the GitHub repository trusted by the frontend deployer role."

  validation {
    condition     = var.github_repository_id > 0 && floor(var.github_repository_id) == var.github_repository_id
    error_message = "github_repository_id must be a positive integer."
  }
}

variable "project_name" {
  type        = string
  description = "Lowercase project identifier used in IAM resource names."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the frontend deployer role."
  default     = {}
}
