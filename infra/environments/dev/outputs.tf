output "github_oidc_provider_arn" {
  description = "Account-level GitHub Actions OIDC provider ARN used by the publisher roles."
  value       = local.github_oidc_provider_arn
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
  value       = { for k, m in module.github_ecr_publisher : k => m.publisher_role_arn }
}

# 각 서비스 레포의 GitHub Environment(dev)에 설정할 변수를 그대로 뽑아준다.
output "github_environment_variables" {
  description = "Per-service GitHub Environment variables to set (AWS_REGION, <SVC>_ECR_REPOSITORY_URL, AWS_ECR_PUBLISH_ROLE_ARN)."
  value = {
    for k, m in module.service_ecr : k => {
      AWS_REGION               = var.aws_region
      ECR_REPOSITORY_URL       = m.repository_url
      AWS_ECR_PUBLISH_ROLE_ARN = module.github_ecr_publisher[k].publisher_role_arn
      GITHUB_OIDC_SUBJECT      = module.github_ecr_publisher[k].github_oidc_subject
    }
  }
}
