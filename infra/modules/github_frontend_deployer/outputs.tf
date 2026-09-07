output "deployer_role_arn" {
  description = "Role ARN used by aws-actions/configure-aws-credentials in the dev Environment."
  value       = aws_iam_role.deployer.arn
}

output "deployer_role_name" {
  description = "IAM role name for the GitHub Actions static frontend deployer."
  value       = aws_iam_role.deployer.name
}

output "github_oidc_subject" {
  description = "Exact GitHub OIDC subject allowed by the frontend deployer trust policy."
  value       = local.github_oidc_subject
}
