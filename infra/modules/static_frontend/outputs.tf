output "bucket_arn" {
  description = "Static frontend S3 bucket ARN."
  value       = aws_s3_bucket.this.arn
}

output "bucket_name" {
  description = "Static frontend S3 bucket name used by the deployment pipeline."
  value       = aws_s3_bucket.this.bucket
}

output "cloudfront_distribution_arn" {
  description = "Static frontend CloudFront distribution ARN."
  value       = aws_cloudfront_distribution.this.arn
}

output "cloudfront_distribution_id" {
  description = "Static frontend CloudFront distribution ID used for invalidations."
  value       = aws_cloudfront_distribution.this.id
}

output "cloudfront_domain_name" {
  description = "CloudFront domain used as the Cloudflare CNAME target."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "public_base_url" {
  description = "Current public frontend base URL."
  value       = "https://${coalesce(var.custom_domain_name, aws_cloudfront_distribution.this.domain_name)}"
}
