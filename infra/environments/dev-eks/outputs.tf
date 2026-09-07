output "cluster_name" {
  description = "EKS cluster name, the kubectl/SSM target for SCRUM-11 verification."
  value       = module.eks_cluster.cluster_name
}

output "vpc_id" {
  description = "VPC ID resolved from the persistent dev State for action-time rendering."
  value       = data.terraform_remote_state.persistent.outputs.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs resolved from the persistent dev State for the ALB action-time render."
  value       = data.terraform_remote_state.persistent.outputs.public_subnet_ids
}

output "api_certificate_arn" {
  description = "Regional ACM certificate ARN resolved from the persistent dev State for the Backend Ingress."
  value       = data.terraform_remote_state.persistent.outputs.api_certificate_arn
}

output "backend_ecr_repository_url" {
  description = "Trusted Backend ECR repository URL resolved from the persistent dev State for immutable image provenance."
  value       = data.terraform_remote_state.persistent.outputs.backend_ecr_repository_url
}

output "backend_application_secret_arn" {
  description = "Exact application Secret ARN consumed only by the approved external bootstrap."
  value       = data.terraform_remote_state.persistent.outputs.backend_application_secret_arn
}

output "profile_image_bucket_name" {
  description = "Profile-image bucket name used by the Backend action-time ConfigMap."
  value       = data.terraform_remote_state.persistent.outputs.profile_image_bucket_name
}

output "profile_image_public_base_url" {
  description = "Profile-image public base URL used by the Backend action-time ConfigMap."
  value       = data.terraform_remote_state.persistent.outputs.profile_image_public_base_url
}

output "cluster_arn" {
  description = "EKS cluster ARN."
  value       = module.eks_cluster.cluster_arn
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks_cluster.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded cluster CA certificate for kubeconfig generation."
  value       = module.eks_cluster.cluster_certificate_authority_data
}

output "cluster_security_group_id" {
  description = "Security group EKS creates and manages for control-plane-to-node communication."
  value       = module.eks_cluster.cluster_security_group_id
}

output "alb_security_group_id" {
  description = "Disposable public ALB security group; the cluster SG remains private."
  value       = aws_security_group.alb.id
}

output "cluster_version" {
  description = "Applied EKS Kubernetes minor version."
  value       = module.eks_cluster.cluster_version
}

output "oidc_provider_arn" {
  description = "Cluster IRSA OIDC provider ARN. SCRUM-11 trusts this when creating workload roles."
  value       = module.eks_cluster.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "Cluster IRSA OIDC issuer URL, without the https:// prefix as required by IAM trust policies."
  value       = module.eks_cluster.oidc_provider_url
}

output "node_group_name" {
  description = "Managed node group name."
  value       = module.eks_cluster.node_group_name
}

output "node_group_status" {
  description = "Managed node group status, for operator plan/apply verification."
  value       = module.eks_cluster.node_group_status
}

output "secrets_kms_key_arn" {
  description = "Dedicated KMS key ARN used for EKS Kubernetes Secrets envelope encryption."
  value       = module.eks_cluster.secrets_kms_key_arn
}

output "admin_access_entry_principal_arns" {
  description = "IAM principal ARNs granted cluster-admin via Access Entries, for operator verification."
  value       = module.eks_cluster.admin_access_entry_principal_arns
}

output "bastion_instance_id" {
  description = "SSM Session Manager target for the SSM-only EKS verification bastion (no public IP, no SSH)."
  value       = aws_instance.bastion.id
}

output "target_persistent_state_key" {
  description = "Persistent dev Terraform State key this EKS deployment reads app_subnet_ids from."
  value       = var.persistent_state_key
}

output "nat_gateway_id" {
  description = "Disposable dev-eks NAT Gateway owning app subnet default routes."
  value       = aws_nat_gateway.this.id
}

output "nat_eip_public_ip" {
  description = "Public EIP attached to the disposable dev-eks NAT Gateway."
  value       = aws_eip.nat.public_ip
}

output "app_route_table_ids" {
  description = "Persistent app route tables receiving the dev-eks-owned default route."
  value       = keys(aws_route.app_default)
}

output "database_address" {
  description = "Private RDS PostgreSQL hostname for the EKS Backend and load-test target contract."
  value       = module.backend_data.database_address
}

output "database_master_secret_arn" {
  description = "RDS-managed master credential Secret ARN for approved external Backend Secret bootstrap."
  value       = module.backend_data.database_master_secret_arn
}

output "database_name" {
  description = "RDS database name used by the Backend/load-test contract."
  value       = module.backend_data.database_name
}

output "database_port" {
  description = "RDS PostgreSQL port."
  value       = module.backend_data.database_port
}

output "database_identifier" {
  description = "RDS DB instance identifier used by monitoring dimensions."
  value       = module.backend_data.database_identifier
}

output "database_security_group_id" {
  description = "EKS-owned PostgreSQL security group consumed by dev-load-test."
  value       = aws_security_group.database.id
}

output "cache_security_group_id" {
  description = "EKS-owned Redis security group consumed by dev-load-test."
  value       = aws_security_group.cache.id
}

output "pod_identity_agent_addon_version" {
  description = "Pinned EKS Pod Identity Agent add-on version."
  value       = aws_eks_addon.pod_identity_agent.addon_version
}

output "backend_pod_identity_role_arn" {
  description = "EKS Pod Identity role ARN associated with travel-planner/backend."
  value       = aws_iam_role.backend_pod_identity.arn
}

output "backend_pod_identity_association_arn" {
  description = "EKS Pod Identity association ARN for the Backend ServiceAccount."
  value       = aws_eks_pod_identity_association.backend.association_arn
}

output "cluster_autoscaler_role_arn" {
  description = "EKS Pod Identity role ARN for the isolated Cluster Autoscaler ServiceAccount."
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "cluster_autoscaler_pod_identity_association_arn" {
  description = "EKS Pod Identity association ARN for kube-system/cluster-autoscaler."
  value       = aws_eks_pod_identity_association.cluster_autoscaler.association_arn
}

output "cluster_autoscaler_discovery_tags" {
  description = "Exact node-group discovery tags required by the EKS Cluster Autoscaler."
  value       = module.eks_cluster.cluster_autoscaler_discovery_tags
}

output "load_balancer_controller_role_arn" {
  description = "EKS Pod Identity role ARN for the isolated AWS Load Balancer Controller ServiceAccount."
  value       = aws_iam_role.load_balancer_controller.arn
}

output "load_balancer_controller_pod_identity_association_arn" {
  description = "EKS Pod Identity association ARN for kube-system/aws-load-balancer-controller."
  value       = aws_eks_pod_identity_association.load_balancer_controller.association_arn
}

output "private_zone_id" {
  description = "Private Route 53 zone ID for dev-eks service endpoints."
  value       = aws_route53_zone.private.zone_id
}

output "private_zone_name" {
  description = "Private Route 53 zone name for dev-eks service endpoints."
  value       = aws_route53_zone.private.name
}

output "database_private_dns_name" {
  description = "Stable private PostgreSQL DNS name."
  value       = aws_route53_record.database.fqdn
}

output "redis_private_dns_name" {
  description = "Stable private Redis DNS name."
  value       = aws_route53_record.redis.fqdn
}

output "monitoring_private_dns_name" {
  description = "Stable private Monitoring DNS name."
  value       = aws_route53_record.monitoring.fqdn
}

output "redis_primary_endpoint" {
  description = "Private TLS Redis primary endpoint."
  value       = module.backend_data.redis_primary_endpoint
}

output "redis_port" {
  description = "Redis TLS port."
  value       = module.backend_data.redis_port
}

output "redis_auth_secret_arn" {
  description = "Generated Redis password Secret ARN for approved external Backend Secret bootstrap."
  value       = module.backend_data.redis_auth_secret_arn
}

output "redis_load_test_user_name" {
  description = "ElastiCache IAM RBAC username consumed by dev-load-test."
  value       = module.backend_data.redis_load_test_user_name
}

output "redis_load_test_user_arn" {
  description = "ElastiCache IAM RBAC user ARN consumed by dev-load-test."
  value       = module.backend_data.redis_load_test_user_arn
}

output "redis_replication_group_arn" {
  description = "ElastiCache replication group ARN consumed by dev-load-test."
  value       = module.backend_data.redis_replication_group_arn
}

output "redis_replication_group_id" {
  description = "ElastiCache replication group ID."
  value       = module.backend_data.redis_replication_group_id
}

output "redis_member_cluster_ids" {
  description = "ElastiCache member cluster IDs for monitoring dimensions."
  value       = module.backend_data.redis_member_cluster_ids
}

output "monitoring_instance_id" {
  description = "Private EKS Monitoring EC2 instance ID."
  value       = module.monitoring_ec2.instance_id
}

output "monitoring_private_ip" {
  description = "Private IP used by Alloy for Prometheus remote-write and Loki pushes."
  value       = module.monitoring_ec2.private_ip
}

output "monitoring_config_bucket_name" {
  description = "Disposable dev-eks Monitoring configuration and Kubernetes bundle bucket."
  value       = module.monitoring_ec2.monitoring_config_bucket_name
}

output "monitoring_config_revision" {
  description = "Monitoring EC2 configuration revision, including the EKS dashboard."
  value       = module.monitoring_ec2.monitoring_config_revision
}

output "monitoring_bundle_prefix" {
  description = "S3 prefix containing the immutable Kustomize source snapshot."
  value       = local.monitoring_bundle_prefix
}

output "monitoring_bundle_revision" {
  description = "SHA-256 revision of the Kustomize source snapshot manifest."
  value       = local.monitoring_bundle_revision
}

output "monitoring_bundle_manifest_key" {
  description = "S3 object key for the Kustomize source snapshot manifest."
  value       = aws_s3_object.monitoring_bundle_manifest.key
}

output "deployment_contract_s3_key" {
  description = "Private S3 key for the non-secret dev-eks deployment contract."
  value       = aws_s3_object.deployment_contract.key
}

output "deployment_contract_sha256" {
  description = "SHA-256 of the exact non-secret deployment contract bytes."
  value       = sha256(local.deployment_contract_json)
}

output "monitoring_endpoint_parameter_name" {
  description = "SSM Parameter containing the EKS Monitoring EC2 private IP."
  value       = module.monitoring_ec2.monitoring_endpoint_parameter_name
}

output "bastion_role_arn" {
  description = "Dedicated SSM bastion IAM role granted the EKS Access Entry and bundle read permissions."
  value       = aws_iam_role.bastion.arn
}
