variable "project_name" {
  type        = string
  description = "Lowercase project identifier used in resource names."
}

variable "environment" {
  type        = string
  description = "Deployment environment name."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private application subnet IDs for the control plane ENIs and managed node group. No public IPs are ever assigned."

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids must contain at least two subnets across separate availability zones."
  }
}

variable "kubernetes_version" {
  type        = string
  description = "EKS control plane Kubernetes minor version."
  default     = "1.35"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must be an EKS-supported 1.NN minor version string."
  }
}

variable "endpoint_private_access" {
  type        = bool
  description = "Whether the cluster API server is reachable from inside the VPC. Nodes always use this path."
  default     = true
}

variable "endpoint_public_access" {
  type        = bool
  description = <<-EOT
    Whether the cluster API server is reachable over the public internet.
    Private by default, matching every other EC2 workload in this repo
    (SSM-only, no public port). Verification instead goes through the
    dev-eks SSM bastion, which reaches the private endpoint from inside the
    VPC. Only flip this on as a deliberate, temporary opt-in (e.g. an
    operator without bastion access debugging from their laptop).
  EOT
  default     = false
}

variable "public_access_cidrs" {
  type        = list(string)
  description = <<-EOT
    CIDR blocks allowed through the public API endpoint. Only meaningful
    when endpoint_public_access is explicitly enabled; unused by default.
  EOT
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.public_access_cidrs) > 0
    error_message = "public_access_cidrs must contain at least one CIDR block when endpoint_public_access is enabled."
  }
}

variable "admin_principal_arns" {
  type        = list(string)
  description = <<-EOT
    IAM principal ARNs (typically the team's shared IAM Identity Center
    permission set role, the same one already used for EC2 SSM access)
    granted EKS cluster-admin via Access Entries. Kubernetes RBAC is
    separate from IAM: without an explicit entry here, an ARN with full
    AWS admin rights still gets "Unauthorized" from kubectl. Empty by
    default; only the identity that ran apply gets the implicit
    cluster-creator admin grant until this is populated.
  EOT
  default     = []
}

variable "node_instance_types" {
  type        = list(string)
  description = "Managed node group EC2 instance types."
  default     = ["t3.medium"]

  validation {
    condition     = length(var.node_instance_types) > 0
    error_message = "node_instance_types must contain at least one instance type."
  }
}

variable "node_min_size" {
  type        = number
  description = "Minimum managed node group size."
  default     = 2

  validation {
    condition     = var.node_min_size >= 1
    error_message = "node_min_size must be at least 1."
  }
}

variable "node_max_size" {
  type        = number
  description = "Maximum managed node group size."
  default     = 4

  validation {
    condition     = var.node_max_size >= 1
    error_message = "node_max_size must be at least 1."
  }
}

variable "node_desired_size" {
  type        = number
  description = "Desired managed node group size."
  default     = 2

  validation {
    condition     = var.node_desired_size >= 1
    error_message = "node_desired_size must be at least 1."
  }
}

variable "cluster_log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention for the control plane log group."
  default     = 30

  validation {
    condition     = var.cluster_log_retention_days >= 1
    error_message = "cluster_log_retention_days must be at least 1."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to EKS resources."
  default     = {}
}
