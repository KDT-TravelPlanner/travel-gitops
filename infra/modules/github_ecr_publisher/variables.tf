variable "ecr_repository_arn" {
  type        = string
  description = "ARN of the only ECR repository that the GitHub publisher may access."

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:ecr:[a-z0-9-]+:[0-9]{12}:repository/[a-z0-9][a-z0-9._/-]*$", var.ecr_repository_arn))
    error_message = "ecr_repository_arn must be a valid private ECR repository ARN."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment name used by the IAM role and GitHub Environment subject."

  validation {
    condition     = can(regex("^[a-z0-9]+(?:[-_][a-z0-9]+)*$", var.environment))
    error_message = "environment must use lowercase letters, numbers, hyphens or underscores."
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
  description = "GitHub repository whose dev Environment may assume the publisher role."

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be a valid GitHub repository name."
  }
}

variable "github_repository_id" {
  type        = number
  description = "Immutable numeric ID of the GitHub repository trusted by the publisher role."

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
  description = "Tags applied to GitHub OIDC IAM resources."
  default     = {}
}

variable "github_oidc_provider_arn" {
  type        = string
  description = "Account-level GitHub Actions OIDC provider ARN (created or looked up by the environment)."

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "github_oidc_provider_arn must be the GitHub Actions OIDC provider ARN."
  }
}


variable "service_name" {
  type        = string
  description = "Service identifier; null preserves the legacy monolith role name."
  default     = null
  validation {
    condition     = var.service_name == null ? true : can(regex("^[a-z][a-z0-9-]*$", var.service_name))
    error_message = "service_name must use lowercase letters, numbers and hyphens."
  }
}

variable "github_environment" {
  type        = string
  description = "Trusted GitHub Environment; null uses environment for legacy compatibility."
  default     = null
  validation {
    condition     = var.github_environment == null ? true : length(trimspace(var.github_environment)) > 0
    error_message = "github_environment must not be empty."
  }
}
