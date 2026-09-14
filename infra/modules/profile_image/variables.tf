variable "acm_certificate_arn" {
  type        = string
  description = "Optional us-east-1 ACM certificate ARN for the CloudFront custom domain."
  default     = null
  nullable    = true

  validation {
    condition     = var.acm_certificate_arn == null || can(regex("^arn:aws[a-z-]*:acm:us-east-1:[0-9]{12}:certificate/", var.acm_certificate_arn))
    error_message = "acm_certificate_arn must be a us-east-1 ACM certificate ARN."
  }
}

variable "allowed_origins" {
  type        = set(string)
  description = "Exact browser origins allowed to upload profile images with presigned PUT URLs."

  validation {
    condition = length(var.allowed_origins) > 0 && alltrue([
      for origin in var.allowed_origins :
      origin != "*" && can(regex("^https?://[^/]+$", origin))
    ])
    error_message = "allowed_origins must contain exact HTTP(S) origins without paths and must not contain a wildcard."
  }
}

variable "bucket_name" {
  type        = string
  description = "Globally unique S3 bucket name for profile images."

  validation {
    condition     = length(var.bucket_name) >= 3 && length(var.bucket_name) <= 63 && can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid 3-63 character lowercase S3 bucket name."
  }
}

variable "custom_domain_name" {
  type        = string
  description = "Optional CloudFront custom domain name."
  default     = null
  nullable    = true

  validation {
    condition     = var.custom_domain_name == null || can(regex("^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$", var.custom_domain_name))
    error_message = "custom_domain_name must be a valid DNS name."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment name."

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to profile image infrastructure."
  default     = {}
}
