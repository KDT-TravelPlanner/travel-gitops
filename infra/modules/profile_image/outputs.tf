output "bucket_arn" {
  description = "ARN of the private profile image bucket."
  value       = aws_s3_bucket.this.arn
}

output "bucket_name" {
  description = "Name of the private profile image bucket."
  value       = aws_s3_bucket.this.bucket
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID."
  value       = aws_cloudfront_distribution.this.id
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name without a URL scheme."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "public_base_url" {
  description = "HTTPS base URL to configure as PROFILE_IMAGE_PUBLIC_BASE_URL."
  value       = "https://${coalesce(var.custom_domain_name, aws_cloudfront_distribution.this.domain_name)}"
}

output "runtime_policy_arn" {
  description = "ARN of the unattached least-privilege backend runtime policy."
  value       = aws_iam_policy.runtime.arn
}
