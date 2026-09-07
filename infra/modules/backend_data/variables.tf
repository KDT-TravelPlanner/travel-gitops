variable "cache_node_type" {
  type        = string
  description = "ElastiCache node type."
  default     = "cache.t4g.micro"
}

variable "cache_security_group_id" {
  type        = string
  description = "Security group that permits Redis access from backend instances."
}

variable "data_subnet_ids" {
  type        = list(string)
  description = "Two isolated data subnet IDs."

  validation {
    condition     = length(var.data_subnet_ids) == 2
    error_message = "data_subnet_ids must contain exactly two subnets."
  }
}

variable "database_name" {
  type        = string
  description = "Initial PostgreSQL database name."
  default     = "travel_diary_dev"
}

variable "database_security_group_id" {
  type        = string
  description = "Security group that permits PostgreSQL access from backend instances."
}

variable "database_username" {
  type        = string
  description = "PostgreSQL master user name. The password is managed by RDS."
  default     = "travel_planner"
}

variable "db_instance_class" {
  type        = string
  description = "RDS PostgreSQL instance class."
  default     = "db.t4g.micro"
}

variable "environment" {
  type        = string
  description = "Deployment environment name."
}

variable "postgres_engine_version" {
  type        = string
  description = "Exact PostgreSQL 17 engine version available in the target AWS region."

  validation {
    condition     = can(regex("^17\\.[0-9]+$", var.postgres_engine_version))
    error_message = "postgres_engine_version must pin an exact PostgreSQL 17 patch version."
  }
}

variable "project_name" {
  type        = string
  description = "Lowercase project identifier used in resource names."
}

variable "redis_engine_version" {
  type        = string
  description = "Redis OSS engine version."
  default     = "7.1"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to data resources."
  default     = {}
}
