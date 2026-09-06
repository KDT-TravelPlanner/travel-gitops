locals {
  github_oidc_audience = "sts.amazonaws.com"

  # 모놀리스와 동일한 subject 형식. repo/owner 를 숫자 ID 로 고정해 이름 변경 공격을 막는다.
  github_oidc_subject = "repo:${var.github_organization}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}:environment:${var.github_environment}"

  role_name = "${var.project_name}-${var.environment}-${var.service_name}-ecr-publisher"

  github_assume_role_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowGitHubEnvironment"
        Effect    = "Allow"
        Action    = ["sts:AssumeRoleWithWebIdentity"]
        Principal = { Federated = var.github_oidc_provider_arn }
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = local.github_oidc_audience
            "token.actions.githubusercontent.com:sub" = local.github_oidc_subject
          }
        }
      },
    ]
  }

  ecr_push_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AuthenticateToEcr"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Sid    = "PushAndVerifyServiceImage"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = [var.ecr_repository_arn]
      },
    ]
  }
}

resource "aws_iam_role" "publisher" {
  name                 = local.role_name
  description          = "GitHub Actions ${var.environment} Environment publisher for ${var.service_name}-service ECR"
  assume_role_policy   = jsonencode(local.github_assume_role_policy)
  max_session_duration = 3600
  tags                 = var.tags
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "${local.role_name}-push"
  role   = aws_iam_role.publisher.name
  policy = jsonencode(local.ecr_push_policy)
}
