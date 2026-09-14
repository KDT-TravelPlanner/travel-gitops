mock_provider "aws" {
  override_during = plan

  mock_resource "aws_iam_role" {
    defaults = {
      arn  = "arn:aws:iam::123456789012:role/kdt-travelplanner-dev-github-ecr-publisher"
      name = "kdt-travelplanner-dev-github-ecr-publisher"
    }
  }
}

variables {
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  ecr_repository_arn       = "arn:aws:ecr:ap-northeast-2:123456789012:repository/kdt-travelplanner-dev-backend"
  environment              = "dev"
  github_organization      = "protove"
  github_owner_id          = 114971169
  github_repository        = "KDT_TravelPlanner"
  github_repository_id     = 1298812222
  project_name             = "kdt-travelplanner"
}

run "trusts_only_the_immutable_dev_environment" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_iam_role.publisher.assume_role_policy).Statement[0].Principal.Federated == var.github_oidc_provider_arn &&
      output.publisher_role_name == "kdt-travelplanner-dev-github-ecr-publisher"
    )
    error_message = "The OIDC provider must use GitHub's issuer and the AWS STS audience only."
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.publisher.assume_role_policy).Statement[0].Action == ["sts:AssumeRoleWithWebIdentity"] &&
      jsondecode(aws_iam_role.publisher.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:protove@114971169/KDT_TravelPlanner@1298812222:environment:dev" &&
      jsondecode(aws_iam_role.publisher.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    )
    error_message = "The publisher trust must require the immutable repository identity, dev Environment and STS audience."
  }

  assert {
    condition     = aws_iam_role.publisher.max_session_duration == 3600
    error_message = "The GitHub publisher session must be limited to one hour."
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
      jsondecode(aws_iam_role_policy.ecr_push.policy).Statement[1].Resource == ["arn:aws:ecr:ap-northeast-2:123456789012:repository/kdt-travelplanner-dev-backend"]
    )
    error_message = "Image push and verification actions must be limited to the backend repository."
  }
}

run "wildcard_repository_is_rejected" {
  command = plan

  variables {
    ecr_repository_arn = "arn:aws:ecr:ap-northeast-2:123456789012:repository/*"
  }

  expect_failures = [var.ecr_repository_arn]
}
