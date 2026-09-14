# container_registry(모놀리스) 이식. 차이: 저장소 이름에 backend 대신 service_name 을 넣어
# 서비스별로 여러 번 호출한다.

variable "environment" {
  type        = string
  description = "Deployment environment name."
}

variable "service_name" {
  type        = string
  description = "Lowercase service identifier (identity, community, travel, maps)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.service_name))
    error_message = "service_name must be lowercase letters, numbers and hyphens."
  }
}

variable "project_name" {
  type        = string
  description = "Lowercase project identifier used in resource names."
}

variable "max_image_count" {
  type        = number
  description = "Maximum total images retained in ECR."
  default     = 20

  validation {
    condition     = var.max_image_count >= 5 && floor(var.max_image_count) == var.max_image_count
    error_message = "max_image_count must be an integer retaining at least five images for rollback."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to ECR resources."
  default     = {}
}
