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
  description = "AWS region for the dev EKS cluster."
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

variable "state_bucket" {
  type        = string
  description = "S3 bucket containing the persistent dev Terraform State."
}

variable "persistent_state_key" {
  type        = string
  description = "Persistent dev Terraform State object key."
  default     = "dev/terraform.tfstate"
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

variable "endpoint_public_access" {
  type        = bool
  description = <<-EOT
    Whether the cluster API server is reachable over the public internet.
    Private by default (matching every other EC2 workload in this repo);
    verification goes through the SSM bastion instead. Only set true as a
    deliberate, temporary opt-in.
  EOT
  default     = false
}

variable "public_access_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed through the public API endpoint. Only meaningful when endpoint_public_access is explicitly enabled."
  default     = ["0.0.0.0/0"]
}

variable "postgres_engine_version" {
  type        = string
  description = "Exact PostgreSQL 17 patch version available in the target AWS region."
  default     = "17.10"

  validation {
    condition     = can(regex("^17\\.[0-9]+$", var.postgres_engine_version))
    error_message = "postgres_engine_version must pin an exact PostgreSQL 17 patch version."
  }
}

variable "pod_identity_agent_version" {
  type        = string
  description = "Exact eks-pod-identity-agent EKS add-on version compatible with kubernetes_version; query and pin immediately before plan."

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", var.pod_identity_agent_version))
    error_message = "pod_identity_agent_version must be an exact vX.Y.Z-eksbuild.N EKS add-on version."
  }
}

variable "monitoring_image_references" {
  type = object({
    prometheus = string
    loki       = string
    grafana    = string
    alloy      = string
  })
  description = "Pinned common Monitoring EC2 image tags. The EKS Alloy bundle additionally pins its Kubernetes image digest in k8s/eks/monitoring."
  default = {
    prometheus = "prom/prometheus:v3.13.1"
    loki       = "grafana/loki:3.7.2"
    grafana    = "grafana/grafana:13.1.0"
    alloy      = "grafana/alloy:v1.16.1"
  }

  validation {
    condition = alltrue([
      can(regex("^prom/prometheus:v[0-9]+\\.[0-9]+\\.[0-9]+$", var.monitoring_image_references.prometheus)),
      can(regex("^grafana/loki:[0-9]+\\.[0-9]+\\.[0-9]+$", var.monitoring_image_references.loki)),
      can(regex("^grafana/grafana:[0-9]+\\.[0-9]+\\.[0-9]+$", var.monitoring_image_references.grafana)),
      can(regex("^grafana/alloy:v[0-9]+\\.[0-9]+\\.[0-9]+$", var.monitoring_image_references.alloy)),
    ])
    error_message = "monitoring_image_references must use the official DockerHub repositories with exact semantic version tags; latest and tagless references are not allowed."
  }
}

variable "grafana_anonymous_viewer_enabled" {
  type        = bool
  description = "Temporary action-time Grafana anonymous Viewer access through an SSM loopback tunnel; default-off."
  default     = false
}

variable "admin_principal_arns" {
  type        = list(string)
  description = <<-EOT
    IAM principal ARNs granted EKS cluster-admin via Access Entries.
    Typically the team's shared IAM Identity Center permission-set role
    already used for EC2 SSM access, so everyone who can SSM into the
    bastion can also kubectl once this is populated. Empty by default; only
    the apply-time cluster creator gets the implicit admin grant until
    then.
  EOT
  default     = []
}

variable "bastion_kubectl_version" {
  type        = string
  description = "Pinned kubectl version installed on the SSM verification bastion, matching kubernetes_version."
  default     = "1.35.6"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.bastion_kubectl_version))
    error_message = "bastion_kubectl_version must be an exact X.Y.Z version."
  }
}

variable "node_instance_types" {
  type        = list(string)
  description = "Managed node group EC2 instance types."
  default     = ["t3.large"]
}

variable "node_min_size" {
  type        = number
  description = "Minimum managed node group size."
  default     = 2
}

variable "node_max_size" {
  type        = number
  description = "Maximum managed node group size."
  default     = 4
}

variable "node_desired_size" {
  type        = number
  description = "Desired managed node group size."
  default     = 2
}
