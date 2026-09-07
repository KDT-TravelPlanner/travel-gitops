variable "app_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for private backend application subnets."
}

variable "availability_zones" {
  type        = list(string)
  description = "Exactly two availability zones used by every subnet tier."

  validation {
    condition     = length(var.availability_zones) == 2 && length(distinct(var.availability_zones)) == 2
    error_message = "availability_zones must contain exactly two distinct zones."
  }
}

variable "data_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for isolated RDS and ElastiCache subnets."
}

variable "environment" {
  type        = string
  description = "Deployment environment name."

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "project_name" {
  type        = string
  description = "Lowercase project identifier used in resource names."
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for public ALB and NAT Gateway subnets."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to network resources."
  default     = {}
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the environment VPC."
}
