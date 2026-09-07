variable "environment" {
  type        = string
  description = "Deployment environment name."
}

variable "max_image_count" {
  type        = number
  description = "Maximum tagged backend images retained in ECR."
  default     = 20

  validation {
    condition     = var.max_image_count >= 5
    error_message = "max_image_count must retain at least five images for rollback."
  }
}

variable "project_name" {
  type        = string
  description = "Lowercase project identifier used in resource names."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to ECR resources."
  default     = {}
}
