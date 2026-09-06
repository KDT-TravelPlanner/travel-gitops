mock_provider "aws" {
  override_during = plan

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-publisher"
    }
  }
  mock_resource "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:ap-northeast-2:123456789012:repository/mock"
      repository_url = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mock"
    }
  }
  mock_data "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  }
}

variables {
  aws_account_id = "123456789012"
}

run "creates_one_ecr_and_one_publisher_per_service" {
  command = plan

  assert {
    condition     = length(module.service_ecr) == 4
    error_message = "Expected an ECR repository for each of the 4 services."
  }

  assert {
    condition     = length(module.github_ecr_publisher) == 4
    error_message = "Expected a publisher role for each of the 4 services."
  }

  assert {
    condition     = module.service_ecr["travel"].repository_arn != null
    error_message = "travel ECR module must be planned."
  }
}

run "references_existing_oidc_provider_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "By default the stack must not create the account-level OIDC provider."
  }

  assert {
    condition     = length(data.aws_iam_openid_connect_provider.github) == 1
    error_message = "By default the stack must look up the existing OIDC provider."
  }
}

run "can_own_the_oidc_provider" {
  command = plan

  variables {
    manage_github_oidc_provider = true
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1
    error_message = "With manage_github_oidc_provider=true the stack must create the provider."
  }
}
