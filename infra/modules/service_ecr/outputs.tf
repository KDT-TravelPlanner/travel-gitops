output "repository_arn" {
  description = "Service ECR repository ARN."
  value       = aws_ecr_repository.this.arn
}

output "repository_url" {
  description = "Service ECR repository URL. Deployments append an immutable sha256 digest."
  value       = aws_ecr_repository.this.repository_url
}

output "repository_name" {
  description = "Service ECR repository name."
  value       = aws_ecr_repository.this.name
}
