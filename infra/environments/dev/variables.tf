variable "aws_account_id" {
  type        = string
  description = "Expected 12-digit AWS account ID."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must contain exactly 12 digits."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region for the ECR repositories."
  default     = "ap-northeast-2"
}

variable "project_name" {
  type        = string
  description = "Lowercase project identifier used in AWS resource names."
  default     = "kdt-travelplanner"

  validation {
    condition     = can(regex("^[a-z0-9]+(?:-[a-z0-9]+)*$", var.project_name))
    error_message = "project_name must use lowercase letters, numbers, and single hyphens."
  }
}

variable "github_organization" {
  type        = string
  description = "GitHub organization that owns the service repositories."
  default     = "protove"
}

variable "github_owner_id" {
  type        = number
  description = "Immutable numeric ID of the GitHub account that owns the service repositories (github.com/protove)."
  default     = 114971169

  validation {
    condition     = var.github_owner_id > 0 && floor(var.github_owner_id) == var.github_owner_id
    error_message = "github_owner_id must be a positive integer."
  }
}

variable "github_environment" {
  type        = string
  description = "GitHub Environment name that each service CI publishes from."
  default     = "dev"
}

# 계정당 GitHub OIDC provider 는 하나뿐이다. 모놀리스(KDT_TravelDiary)의 dev 스택이
# 이미 만들었다면 false 로 두고 data 로 참조한다. 계정에 아직 없다면 true 로 이 스택이 만든다.
variable "manage_github_oidc_provider" {
  type        = bool
  description = "Create the account-level GitHub OIDC provider here (true) or reference the existing one (false)."
  default     = false
}

variable "services" {
  type = map(object({
    github_repository    = string
    github_repository_id = number
  }))
  description = "Service key -> its GitHub repository name and immutable numeric ID. travel-common is a JAR, not a container."

  default = {
    identity = {
      github_repository    = "identity-service"
      github_repository_id = 1352173512
    }
    community = {
      github_repository    = "community-service"
      github_repository_id = 1352173505
    }
    travel = {
      github_repository    = "travel-service"
      github_repository_id = 1352173475
    }
    maps = {
      github_repository    = "maps-service"
      github_repository_id = 1352173510
    }
  }
}

variable "max_image_count" {
  type        = number
  description = "Tagged images retained per service ECR repository."
  default     = 20
}
