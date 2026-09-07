mock_provider "aws" {
  override_during = plan

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn                         = "arn:aws:s3:::kdt-travelplanner-dev-profile-images-123456789012"
      bucket                      = "kdt-travelplanner-dev-profile-images-123456789012"
      bucket_regional_domain_name = "kdt-travelplanner-dev-profile-images-123456789012.s3.ap-northeast-2.amazonaws.com"
      id                          = "kdt-travelplanner-dev-profile-images-123456789012"
    }
  }

  mock_resource "aws_cloudfront_distribution" {
    defaults = {
      arn         = "arn:aws:cloudfront::123456789012:distribution/E123456789"
      domain_name = "d111111abcdef8.cloudfront.net"
      id          = "E123456789"
    }
  }

  mock_resource "aws_cloudfront_origin_access_control" {
    defaults = {
      id = "E123OAC"
    }
  }

  mock_resource "aws_cloudfront_response_headers_policy" {
    defaults = {
      id = "E123HEADERS"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/kdt-travelplanner-dev-profile-images-runtime"
    }
  }

  mock_data "aws_cloudfront_cache_policy" {
    defaults = {
      id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    }
  }
}

variables {
  allowed_origins = ["http://localhost:3000"]
  bucket_name     = "kdt-travelplanner-dev-profile-images-123456789012"
  environment     = "dev"
}

run "profile_image_security_controls" {
  command = plan

  assert {
    condition     = aws_s3_bucket.this.force_destroy == false
    error_message = "The profile image bucket must never force-delete objects."
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.this.block_public_acls &&
      aws_s3_bucket_public_access_block.this.block_public_policy &&
      aws_s3_bucket_public_access_block.this.ignore_public_acls &&
      aws_s3_bucket_public_access_block.this.restrict_public_buckets
    )
    error_message = "All profile image bucket public access controls must be enabled."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "The profile image bucket must explicitly use SSE-S3 AES256 encryption."
  }

  assert {
    condition     = aws_s3_bucket_versioning.this.versioning_configuration[0].status == "Enabled"
    error_message = "The profile image bucket must have versioning enabled."
  }

  assert {
    condition     = toset(one(aws_s3_bucket_cors_configuration.this.cors_rule).allowed_methods) == toset(["PUT"])
    error_message = "Browser CORS must only allow PUT uploads."
  }

  assert {
    condition     = toset(one(aws_s3_bucket_cors_configuration.this.cors_rule).allowed_headers) == toset(["Content-Type"])
    error_message = "Browser CORS must only allow the Content-Type request header."
  }

  assert {
    condition     = aws_cloudfront_origin_access_control.this.signing_behavior == "always" && aws_cloudfront_origin_access_control.this.signing_protocol == "sigv4"
    error_message = "CloudFront must always use SigV4 OAC signing."
  }

  assert {
    condition     = toset(aws_cloudfront_distribution.this.default_cache_behavior[0].allowed_methods) == toset(["GET", "HEAD"])
    error_message = "CloudFront must expose only GET and HEAD."
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].viewer_protocol_policy == "redirect-to-https"
    error_message = "CloudFront viewers must be redirected to HTTPS."
  }

  assert {
    condition     = aws_cloudfront_response_headers_policy.security.security_headers_config[0].content_type_options[0].override
    error_message = "CloudFront must emit X-Content-Type-Options: nosniff."
  }
}

run "runtime_policy_is_scoped_to_profile_images" {
  command = plan

  assert {
    condition     = toset(data.aws_iam_policy_document.runtime.statement[0].actions) == toset(["s3:GetObject", "s3:PutObject"])
    error_message = "Runtime object access must contain only GetObject and PutObject."
  }

  assert {
    condition     = alltrue([for resource in data.aws_iam_policy_document.runtime.statement[0].resources : endswith(resource, "/users/*/profile/*")])
    error_message = "Runtime object access must be restricted to users/*/profile/*."
  }

  assert {
    condition     = toset(data.aws_iam_policy_document.runtime.statement[1].actions) == toset(["s3:ListBucket"])
    error_message = "Bucket-level runtime access must contain only ListBucket."
  }
}

run "custom_domain_requires_certificate" {
  command = plan

  variables {
    custom_domain_name = "image.kdt-travelplanner.protove.net"
  }

  expect_failures = [aws_cloudfront_distribution.this]
}

run "wildcard_cors_origin_is_rejected" {
  command = plan

  variables {
    allowed_origins = ["*"]
  }

  expect_failures = [var.allowed_origins]
}
