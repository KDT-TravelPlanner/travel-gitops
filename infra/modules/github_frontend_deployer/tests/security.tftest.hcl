mock_provider "aws" {
  override_during = plan

  mock_resource "aws_iam_role" {
    defaults = {
      arn  = "arn:aws:iam::123456789012:role/kdt-travelplanner-dev-github-frontend-deployer"
      name = "kdt-travelplanner-dev-github-frontend-deployer"
    }
  }
}

variables {
  cloudfront_distribution_arn = "arn:aws:cloudfront::123456789012:distribution/E123FRONTEND"
  environment                 = "dev"
  frontend_bucket_arn         = "arn:aws:s3:::kdt-travelplanner-dev-frontend-123456789012"
  github_oidc_provider_arn    = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  github_organization         = "protove"
  github_owner_id             = 114971169
  github_repository           = "KDT_TravelPlanner"
  github_repository_id        = 1298812222
  project_name                = "kdt-travelplanner"
}

run "trusts_only_the_immutable_dev_environment" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_iam_role.deployer.assume_role_policy).Statement[0].Principal.Federated == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" &&
      jsondecode(aws_iam_role.deployer.assume_role_policy).Statement[0].Action == ["sts:AssumeRoleWithWebIdentity"] &&
      jsondecode(aws_iam_role.deployer.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:protove@114971169/KDT_TravelPlanner@1298812222:environment:dev" &&
      jsondecode(aws_iam_role.deployer.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    )
    error_message = "The deployer trust must require the existing provider, immutable repository identity, dev Environment and STS audience."
  }

  assert {
    condition     = aws_iam_role.deployer.max_session_duration == 3600
    error_message = "The frontend deployer session must be limited to one hour."
  }
}

run "invalid_github_ids_are_rejected" {
  command = plan

  variables {
    github_owner_id      = 0
    github_repository_id = -1
  }

  expect_failures = [
    var.github_owner_id,
    var.github_repository_id,
  ]
}

run "deployment_is_scoped_to_one_bucket_and_distribution" {
  command = plan

  assert {
    condition = (
      toset(jsondecode(aws_iam_role_policy.frontend_deploy.policy).Statement[0].Action) == toset(["s3:GetBucketLocation", "s3:ListBucket"]) &&
      jsondecode(aws_iam_role_policy.frontend_deploy.policy).Statement[0].Resource == ["arn:aws:s3:::kdt-travelplanner-dev-frontend-123456789012"]
    )
    error_message = "Bucket metadata access must be limited to the frontend bucket."
  }

  assert {
    condition = (
      toset(jsondecode(aws_iam_role_policy.frontend_deploy.policy).Statement[1].Action) == toset(["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]) &&
      jsondecode(aws_iam_role_policy.frontend_deploy.policy).Statement[1].Resource == ["arn:aws:s3:::kdt-travelplanner-dev-frontend-123456789012/*"]
    )
    error_message = "Release sync must be limited to objects in the frontend bucket."
  }

  assert {
    condition = (
      toset(jsondecode(aws_iam_role_policy.frontend_deploy.policy).Statement[2].Action) == toset(["cloudfront:CreateInvalidation", "cloudfront:GetDistribution", "cloudfront:GetInvalidation"]) &&
      jsondecode(aws_iam_role_policy.frontend_deploy.policy).Statement[2].Resource == ["arn:aws:cloudfront::123456789012:distribution/E123FRONTEND"]
    )
    error_message = "CloudFront access must be limited to invalidation and read operations on one distribution."
  }
}

run "wildcard_targets_are_rejected" {
  command = plan

  variables {
    cloudfront_distribution_arn = "arn:aws:cloudfront::123456789012:distribution/*"
    frontend_bucket_arn         = "arn:aws:s3:::*"
  }

  expect_failures = [
    var.cloudfront_distribution_arn,
    var.frontend_bucket_arn,
  ]
}
