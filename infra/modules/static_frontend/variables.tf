variable "acm_certificate_arn" {
  type        = string
  description = "Optional issued us-east-1 ACM certificate ARN for the frontend custom domain."
  default     = null
  nullable    = true

  validation {
    condition     = var.acm_certificate_arn == null || can(regex("^arn:aws[a-z-]*:acm:us-east-1:[0-9]{12}:certificate/", var.acm_certificate_arn))
    error_message = "acm_certificate_arn must be a us-east-1 ACM certificate ARN."
  }
}

variable "bucket_name" {
  type        = string
  description = "Globally unique private S3 bucket name for static frontend releases."

  validation {
    condition     = length(var.bucket_name) >= 3 && length(var.bucket_name) <= 63 && can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid 3-63 character lowercase S3 bucket name."
  }
}

variable "custom_domain_name" {
  type        = string
  description = "Optional CloudFront frontend custom domain name."
  default     = null
  nullable    = true

  validation {
    condition     = var.custom_domain_name == null || can(regex("^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$", var.custom_domain_name))
    error_message = "custom_domain_name must be a valid lowercase DNS name."
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

variable "html_cache_ttl_seconds" {
  type        = number
  description = "CloudFront TTL for HTML and route documents."
  default     = 0

  validation {
    condition     = var.html_cache_ttl_seconds >= 0 && var.html_cache_ttl_seconds <= 3600
    error_message = "html_cache_ttl_seconds must be between 0 and 3600 seconds."
  }
}

variable "project_name" {
  type        = string
  description = "Lowercase project identifier used in resource names."

  validation {
    condition     = can(regex("^[a-z0-9]+(?:-[a-z0-9]+)*$", var.project_name))
    error_message = "project_name must use lowercase letters, numbers, and single hyphens."
  }
}

variable "static_cache_ttl_seconds" {
  type        = number
  description = "CloudFront TTL for immutable Next.js static assets."
  default     = 31536000

  validation {
    condition     = var.static_cache_ttl_seconds >= 86400 && var.static_cache_ttl_seconds <= 31536000
    error_message = "static_cache_ttl_seconds must be between one day and one year."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to frontend infrastructure."
  default     = {}
}
