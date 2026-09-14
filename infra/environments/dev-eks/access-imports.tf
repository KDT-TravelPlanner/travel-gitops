# SCRUM-81: plan-time recovery of entries created by EKS bootstrap or a
# previous interrupted deployment. Empty maps keep fresh creation unchanged.
# Import blocks do not change remote state until the saved plan is applied.
variable "existing_admin_entry_imports" {
  type        = map(string)
  default     = {}
  description = "Admin principal ARN to existing cluster:principal import ID."
  validation {
    condition     = alltrue([for arn, id in var.existing_admin_entry_imports : contains(var.admin_principal_arns, arn) && endswith(id, ":${arn}")])
    error_message = "Only configured admin principals with matching import IDs may be adopted."
  }
}

variable "existing_admin_policy_imports" {
  type        = map(string)
  default     = {}
  description = "Admin principal ARN to existing cluster#principal#policy import ID."
  validation {
    condition     = alltrue([for arn, id in var.existing_admin_policy_imports : contains(var.admin_principal_arns, arn) && endswith(id, "#${arn}#arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy")])
    error_message = "Only configured admins and the exact cluster-admin policy may be adopted."
  }
}

import {
  for_each = var.existing_admin_entry_imports
  to       = module.eks_cluster.aws_eks_access_entry.admin[each.key]
  id       = each.value
}

import {
  for_each = var.existing_admin_policy_imports
  to       = module.eks_cluster.aws_eks_access_policy_association.admin[each.key]
  id       = each.value
}
