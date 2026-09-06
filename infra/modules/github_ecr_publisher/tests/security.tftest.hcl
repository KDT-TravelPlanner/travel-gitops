mock_provider "aws" {
  override_during = plan

  mock_resource "aws_iam_role" {
    defaults = {
      arn  = "arn:aws:iam::123456789012:role/kdt-travelplanner-dev-identity-ecr-publisher"
      name = "kdt-travelplanner-dev-identity-ecr-publisher"
    }
  }
}

variables {
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  ecr_repository_arn       = "arn:aws:ecr:ap-northeast-2:123456789012:repository/kdt-travelplanner-dev-identity"
  service_name             = "identity"
  environment              = "dev"
  github_organization      = "protove"
  github_owner_id          = 114971169
  github_repository        = "identity-service"
  github_repository_id     = 1352173512
  project_name             = "kdt-travelplanner"
}

run "trusts_only_the_immutable_service_repo_dev_environment" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_iam_role.publisher.assume_role_policy).Statement[0].Action == ["sts:AssumeRoleWithWebIdentity"] &&
      jsondecode(aws_iam_role.publisher.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:protove@114971169/identity-service@1352173512:environment:dev" &&
      jsondecode(aws_iam_role.publisher.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    )
    error_message = "The publisher trust must require the immutable repository identity, dev Environment and STS audience."
  }

  assert {
    condition     = aws_iam_role.publisher.max_session_duration == 3600
    error_message = "The GitHub publisher session must be limited to one hour."
  }

  assert {
    condition     = aws_iam_role.publisher.name == "kdt-travelplanner-dev-identity-ecr-publisher"
    error_message = "Role name must include the service."
  }
}

run "push_is_scoped_to_one_repository" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_iam_role_policy.ecr_push.policy).Statement[0].Action == ["ecr:GetAuthorizationToken"] &&
      jsondecode(aws_iam_role_policy.ecr_push.policy).Statement[0].Resource == ["*"]
    )
    error_message = "Only the registry authorization token action may use a wildcard resource."
  }

  assert {
    condition = (
      toset(jsondecode(aws_iam_role_policy.ecr_push.policy).Statement[1].Action) == toset([
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeImages",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
      ]) &&
      jsondecode(aws_iam_role_policy.ecr_push.policy).Statement[1].Resource == ["arn:aws:ecr:ap-northeast-2:123456789012:repository/kdt-travelplanner-dev-identity"]
    )
    error_message = "Image push and verification actions must be limited to the one service repository."
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

run "wildcard_repository_is_rejected" {
  command = plan

  variables {
    ecr_repository_arn = "arn:aws:ecr:ap-northeast-2:123456789012:repository/*"
  }

  expect_failures = [var.ecr_repository_arn]
}

run "non_github_oidc_provider_is_rejected" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/accounts.google.com"
  }

  expect_failures = [var.github_oidc_provider_arn]
}
