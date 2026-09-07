variable "app_subnet_id" {
  type        = string
  description = "Private application subnet ID for the Monitoring EC2."
}

variable "aws_region" {
  type        = string
  description = "AWS region used by runtime SDK calls."
}

variable "environment" {
  type        = string
  description = "Deployment environment name."
}

variable "platform" {
  type        = string
  description = "Monitoring deployment profile. EC2 keeps the legacy discovery/bind behavior; EKS enables the remote-write receiver."
  default     = "ec2"

  validation {
    condition     = contains(["ec2", "eks"], var.platform)
    error_message = "platform must be either ec2 or eks."
  }
}

variable "grafana_anonymous_viewer_enabled" {
  type        = bool
  description = "Action-time-only Grafana anonymous Viewer access for an authorized loopback/SSM capture; remains disabled by default."
  default     = false
}

variable "name_suffix" {
  type        = string
  description = "Optional lowercase suffix used to keep disposable platform resources uniquely named."
  default     = ""

  validation {
    condition     = var.name_suffix == "" || can(regex("^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$", var.name_suffix))
    error_message = "name_suffix must be empty or use lowercase letters, numbers, and single hyphens."
  }
}

variable "instance_type" {
  type        = string
  description = "Monitoring EC2 instance type."
  default     = "t3.small"
}

variable "monitoring_bucket_name" {
  type        = string
  description = "S3 bucket name for uploaded Prometheus, Loki and Grafana config files."
}

variable "prometheus_image_reference" {
  type        = string
  description = "Official DockerHub Prometheus image pinned to an exact semantic version."

  validation {
    condition     = can(regex("^prom/prometheus:v[0-9]+\\.[0-9]+\\.[0-9]+$", var.prometheus_image_reference))
    error_message = "prometheus_image_reference must be prom/prometheus with an exact vX.Y.Z tag."
  }
}

variable "loki_image_reference" {
  type        = string
  description = "Official DockerHub Loki image pinned to an exact semantic version."

  validation {
    condition     = can(regex("^grafana/loki:[0-9]+\\.[0-9]+\\.[0-9]+$", var.loki_image_reference))
    error_message = "loki_image_reference must be grafana/loki with an exact X.Y.Z tag."
  }
}

variable "grafana_image_reference" {
  type        = string
  description = "Official DockerHub Grafana image pinned to an exact semantic version."

  validation {
    condition     = can(regex("^grafana/grafana:[0-9]+\\.[0-9]+\\.[0-9]+$", var.grafana_image_reference))
    error_message = "grafana_image_reference must be grafana/grafana with an exact X.Y.Z tag."
  }
}

variable "monitoring_endpoint_parameter_name" {
  type        = string
  description = "SSM Parameter Store path where the Monitoring EC2 private IP is published for Alloy log shipping."

  validation {
    condition     = can(regex("^/[a-zA-Z0-9_.\\-/]+$", var.monitoring_endpoint_parameter_name))
    error_message = "monitoring_endpoint_parameter_name must be an absolute SSM parameter path starting with /."
  }
}

variable "monitoring_security_group_id" {
  type        = string
  description = "Security group attached to the Monitoring EC2."
}

variable "project_name" {
  type        = string
  description = "Lowercase project identifier used in resource names."
}

variable "root_volume_size_gib" {
  type        = number
  description = "Encrypted gp3 root volume size for Prometheus/Loki/Grafana data."
  default     = 30
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to monitoring resources."
  default     = {}
}
