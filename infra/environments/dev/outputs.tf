output "profile_image_bucket_name" {
  description = "Value for PROFILE_IMAGE_STORAGE_BUCKET."
  value       = module.profile_image.bucket_name
}

output "profile_image_cloudfront_distribution_id" {
  description = "CloudFront distribution ID for profile images."
  value       = module.profile_image.cloudfront_distribution_id
}

output "profile_image_public_base_url" {
  description = "Value for PROFILE_IMAGE_PUBLIC_BASE_URL."
  value       = module.profile_image.public_base_url
}

output "profile_image_runtime_policy_arn" {
  description = "Unattached runtime policy ARN for the backend SSO permission set or runtime role."
  value       = module.profile_image.runtime_policy_arn
}

output "frontend_bucket_name" {
  description = "Private S3 bucket used by the static frontend deployment pipeline."
  value       = module.static_frontend.bucket_name
}

output "frontend_certificate_arn" {
  description = "us-east-1 ACM certificate ARN for the frontend CloudFront alias."
  value       = aws_acm_certificate.frontend.arn
}

output "frontend_certificate_dns_validation_records" {
  description = "CNAME records that an operator must add to Cloudflare with proxy disabled."
  value = {
    for option in aws_acm_certificate.frontend.domain_validation_options : option.domain_name => {
      name  = option.resource_record_name
      type  = option.resource_record_type
      value = option.resource_record_value
    }
  }
}

output "frontend_cloudflare_cname_target" {
  description = "DNS-only Cloudflare CNAME target for the frontend custom domain."
  value       = module.static_frontend.cloudfront_domain_name
}

output "frontend_cloudfront_distribution_id" {
  description = "CloudFront distribution ID used by the frontend release pipeline."
  value       = module.static_frontend.cloudfront_distribution_id
}

output "frontend_public_base_url" {
  description = "Current frontend URL; CloudFront default domain until the custom alias is enabled."
  value       = module.static_frontend.public_base_url
}

output "api_certificate_arn" {
  description = "Regional ACM certificate ARN. Use it only after Cloudflare DNS validation completes."
  value       = aws_acm_certificate.api.arn
}

output "api_certificate_dns_validation_records" {
  description = "CNAME records that an operator must add to Cloudflare with proxy disabled."
  value = {
    for option in aws_acm_certificate.api.domain_validation_options : option.domain_name => {
      name  = option.resource_record_name
      type  = option.resource_record_type
      value = option.resource_record_value
    }
  }
}

output "app_route_table_ids" {
  description = "Private application route tables used by the ephemeral NAT Gateway."
  value       = module.network.app_route_table_ids
}

output "app_subnet_ids" {
  description = "Private backend application subnet IDs."
  value       = module.network.app_subnet_ids
}

output "backend_application_secret_arn" {
  description = "Secret container ARN. The operator must create a value before starting dev-runtime."
  value       = aws_secretsmanager_secret.backend_application.arn
}

output "backend_ecr_repository_arn" {
  description = "Backend ECR repository ARN."
  value       = module.container_registry.repository_arn
}

output "backend_ecr_repository_url" {
  description = "Backend ECR repository URL. Runtime images must append an immutable digest."
  value       = module.container_registry.repository_url
}

output "github_frontend_deployer_role_arn" {
  description = "Role ARN for the GitHub Actions dev Environment static frontend deployment job."
  value       = module.github_frontend_deployer.deployer_role_arn
}

output "github_frontend_deployer_subject" {
  description = "Exact GitHub OIDC subject enforced by the frontend deployment role."
  value       = module.github_frontend_deployer.github_oidc_subject
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider managed by the persistent dev State."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "data_subnet_ids" {
  description = "Isolated RDS and Redis subnet IDs."
  value       = module.network.data_subnet_ids
}

output "public_subnet_ids" {
  description = "Public ALB and NAT Gateway subnet IDs."
  value       = module.network.public_subnet_ids
}

output "vpc_id" {
  description = "Persistent dev VPC ID."
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "Persistent dev VPC CIDR."
  value       = module.network.vpc_cidr
}

output "ecr_repository_urls" {
  description = "Service key -> ECR repository URL. CI pushes <url>:<github.sha>."
  value       = { for k, m in module.service_ecr : k => m.repository_url }
}

output "ecr_repository_arns" {
  description = "Service key -> ECR repository ARN."
  value       = { for k, m in module.service_ecr : k => m.repository_arn }
}

output "publisher_role_arns" {
  description = "Service key -> IAM role ARN for that service's GitHub Actions ECR publisher."
  value       = { for k, m in module.service_github_ecr_publisher : k => m.publisher_role_arn }
}

# 각 서비스 레포의 GitHub Environment(dev)에 설정할 변수를 그대로 뽑아준다.
output "github_environment_variables" {
  description = "Per-service GitHub Environment variables to set (AWS_REGION, ECR_REPOSITORY_URL, AWS_ECR_PUBLISH_ROLE_ARN)."
  value = {
    for k, m in module.service_ecr : k => {
      AWS_REGION               = var.aws_region
      ECR_REPOSITORY_URL       = m.repository_url
      AWS_ECR_PUBLISH_ROLE_ARN = module.service_github_ecr_publisher[k].publisher_role_arn
      GITHUB_OIDC_SUBJECT      = module.service_github_ecr_publisher[k].github_oidc_subject
    }
  }
}
