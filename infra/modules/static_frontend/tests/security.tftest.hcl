mock_provider "aws" {
  override_during = plan

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn                         = "arn:aws:s3:::kdt-travelplanner-dev-frontend-123456789012"
      bucket                      = "kdt-travelplanner-dev-frontend-123456789012"
      bucket_regional_domain_name = "kdt-travelplanner-dev-frontend-123456789012.s3.ap-northeast-2.amazonaws.com"
      id                          = "kdt-travelplanner-dev-frontend-123456789012"
    }
  }

  mock_resource "aws_cloudfront_distribution" {
    defaults = {
      arn         = "arn:aws:cloudfront::123456789012:distribution/E123FRONTEND"
      domain_name = "d111111frontend.cloudfront.net"
      id          = "E123FRONTEND"
    }
  }

  mock_resource "aws_cloudfront_origin_access_control" {
    defaults = {
      id = "E123OAC"
    }
  }

  mock_resource "aws_cloudfront_function" {
    defaults = {
      arn = "arn:aws:cloudfront::123456789012:function/kdt-travelplanner-dev-frontend-route-rewrite"
    }
  }

  mock_resource "aws_cloudfront_cache_policy" {
    defaults = {
      id = "cache-policy-id"
    }
  }

  mock_resource "aws_cloudfront_response_headers_policy" {
    defaults = {
      id = "response-headers-policy-id"
    }
  }
}

variables {
  bucket_name  = "kdt-travelplanner-dev-frontend-123456789012"
  environment  = "dev"
  project_name = "kdt-travelplanner"
}

run "static_frontend_security_and_cache_controls" {
  command = plan

  assert {
    condition     = aws_s3_bucket.this.force_destroy == false
    error_message = "The frontend bucket must never force-delete release objects."
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.this.block_public_acls &&
      aws_s3_bucket_public_access_block.this.block_public_policy &&
      aws_s3_bucket_public_access_block.this.ignore_public_acls &&
      aws_s3_bucket_public_access_block.this.restrict_public_buckets
    )
    error_message = "All frontend bucket public access controls must be enabled."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "The frontend bucket must explicitly use SSE-S3 AES256 encryption."
  }

  assert {
    condition     = aws_s3_bucket_versioning.this.versioning_configuration[0].status == "Enabled"
    error_message = "The frontend bucket must have versioning enabled for release rollback."
  }

  assert {
    condition     = aws_cloudfront_origin_access_control.this.signing_behavior == "always" && aws_cloudfront_origin_access_control.this.signing_protocol == "sigv4"
    error_message = "CloudFront must always use SigV4 OAC signing."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_root_object == "index.html"
    error_message = "CloudFront must serve index.html at the root."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].viewer_protocol_policy == "redirect-to-https"
    error_message = "Frontend viewers must be redirected to HTTPS."
  }

  assert {
    condition     = toset(aws_cloudfront_distribution.this.default_cache_behavior[0].allowed_methods) == toset(["GET", "HEAD"])
    error_message = "The static frontend must expose only GET and HEAD."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.ordered_cache_behavior[0].path_pattern == "/_next/static/*"
    error_message = "Next.js immutable assets must use a dedicated cache behavior."
  }

  assert {
    condition     = aws_cloudfront_cache_policy.html.default_ttl == 0 && aws_cloudfront_cache_policy.html.max_ttl == 0
    error_message = "HTML must not be retained in the CloudFront cache by default."
  }

  assert {
    condition = (
      aws_cloudfront_cache_policy.html.parameters_in_cache_key_and_forwarded_to_origin[0].enable_accept_encoding_brotli == false &&
      aws_cloudfront_cache_policy.html.parameters_in_cache_key_and_forwarded_to_origin[0].enable_accept_encoding_gzip == false
    )
    error_message = "CloudFront does not allow Accept-Encoding cache keys when HTML caching is disabled."
  }

  assert {
    condition     = aws_cloudfront_cache_policy.static.default_ttl == 31536000 && aws_cloudfront_cache_policy.static.min_ttl == 31536000
    error_message = "Hashed static assets must use the one-year immutable cache policy."
  }

  assert {
    condition     = one(one(aws_cloudfront_response_headers_policy.html.custom_headers_config).items).value == "no-cache, no-store, must-revalidate"
    error_message = "HTML responses must explicitly prevent browser caching."
  }

  assert {
    condition     = one(one(aws_cloudfront_response_headers_policy.static.custom_headers_config).items).value == "public, max-age=31536000, immutable"
    error_message = "Static asset responses must be marked immutable."
  }

  assert {
    condition     = strcontains(aws_cloudfront_function.route_rewrite.code, "request.uri.endsWith(\"/\")")
    error_message = "The viewer-request function must rewrite directory routes."
  }
}

run "bucket_policy_allows_only_the_distribution" {
  command = plan

  assert {
    condition     = toset(data.aws_iam_policy_document.bucket.statement[1].actions) == toset(["s3:GetObject"])
    error_message = "CloudFront may only read frontend objects."
  }

  assert {
    condition     = toset(one(data.aws_iam_policy_document.bucket.statement[1].principals).identifiers) == toset(["cloudfront.amazonaws.com"])
    error_message = "Only the CloudFront service principal may read frontend objects."
  }

  assert {
    condition     = toset(one(data.aws_iam_policy_document.bucket.statement[1].condition).values) == toset([aws_cloudfront_distribution.this.arn])
    error_message = "The bucket policy must be scoped to this CloudFront distribution."
  }
}

run "custom_domain_requires_certificate" {
  command = plan

  variables {
    custom_domain_name = "kdt-travelplanner.protove.net"
  }

  expect_failures = [aws_cloudfront_distribution.this]
}
