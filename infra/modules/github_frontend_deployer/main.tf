locals {
  github_oidc_audience = "sts.amazonaws.com"
  github_oidc_subject  = "repo:${var.github_organization}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}:environment:${var.environment}"
  role_name            = "${var.project_name}-${var.environment}-github-frontend-deployer"

  github_assume_role_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowGitHubDevEnvironment"
        Effect = "Allow"
        Action = ["sts:AssumeRoleWithWebIdentity"]
        Principal = {
          Federated = var.github_oidc_provider_arn
        }
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = local.github_oidc_audience
            "token.actions.githubusercontent.com:sub" = local.github_oidc_subject
          }
        }
      },
    ]
  }

  frontend_deploy_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadFrontendBucketMetadata"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [var.frontend_bucket_arn]
      },
      {
        Sid    = "SyncFrontendReleaseObjects"
        Effect = "Allow"
        Action = [
          "s3:DeleteObject",
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = ["${var.frontend_bucket_arn}/*"]
      },
      {
        Sid    = "InvalidateFrontendDistribution"
        Effect = "Allow"
        Action = [
          "cloudfront:CreateInvalidation",
          "cloudfront:GetDistribution",
          "cloudfront:GetInvalidation",
        ]
        Resource = [var.cloudfront_distribution_arn]
      },
    ]
  }
}

resource "aws_iam_role" "deployer" {
  name                 = local.role_name
  description          = "GitHub Actions ${var.environment} Environment deployer for the static frontend"
  assume_role_policy   = jsonencode(local.github_assume_role_policy)
  max_session_duration = 3600
  tags                 = var.tags
}

resource "aws_iam_role_policy" "frontend_deploy" {
  name   = "${local.role_name}-deploy"
  role   = aws_iam_role.deployer.name
  policy = jsonencode(local.frontend_deploy_policy)
}
