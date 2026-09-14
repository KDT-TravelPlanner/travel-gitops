output "repository_arn" {
  description = "Backend ECR repository ARN."
  value       = aws_ecr_repository.this.arn
}

output "repository_url" {
  description = "Backend ECR repository URL. Deployments append an immutable sha256 digest."
  value       = aws_ecr_repository.this.repository_url
}
