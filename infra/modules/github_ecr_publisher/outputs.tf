output "github_oidc_provider_arn" {
  description = "Account-level GitHub Actions OIDC provider ARN."
  value       = var.github_oidc_provider_arn
}

output "github_oidc_subject" {
  description = "Exact GitHub OIDC subject allowed by the role trust policy."
  value       = local.github_oidc_subject
}

output "publisher_role_arn" {
  description = "Role ARN used by aws-actions/configure-aws-credentials in the dev Environment."
  value       = aws_iam_role.publisher.arn
}

output "publisher_role_name" {
  description = "IAM role name for the GitHub Actions ECR publisher."
  value       = aws_iam_role.publisher.name
}
