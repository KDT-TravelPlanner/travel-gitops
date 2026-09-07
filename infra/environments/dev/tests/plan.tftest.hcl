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
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  }
  mock_resource "aws_vpc" {
    defaults = { id = "vpc-0123456789abcdef0" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-frontend-bucket" }
  }
  mock_resource "aws_cloudfront_distribution" {
    defaults = { arn = "arn:aws:cloudfront::123456789012:distribution/EXAMPLE123" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

}

mock_provider "aws" {
  alias           = "us_east_1"
  override_during = plan
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
    condition     = length(module.service_github_ecr_publisher) == 4
    error_message = "Expected a publisher role for each of the 4 services."
  }

  assert {
    condition     = module.service_ecr["travel"].repository_arn != null
    error_message = "travel ECR module must be planned."
  }
}


run "preserves_persistent_dev_output_and_oidc_contracts" {
  command = plan
  assert {
    condition     = output.backend_ecr_repository_url == module.container_registry.repository_url && output.vpc_id == module.network.vpc_id
    error_message = "Original persistent dev resource addresses and output contracts must be preserved."
  }
  assert {
    condition     = output.github_oidc_provider_arn == module.github_ecr_publisher.github_oidc_provider_arn
    error_message = "The legacy publisher must use the shared root OIDC provider."
  }
  assert {
    condition     = module.service_github_ecr_publisher["identity"].github_oidc_subject == "repo:protove@114971169/identity-service@1352173512:environment:dev"
    error_message = "Service publishers must retain exact repository identity and environment scope."
  }
}

run "four_independent_publishers_share_one_provider" {
  command = plan
  assert {
    condition     = toset(keys(output.ecr_repository_urls)) == toset(["identity", "community", "travel", "maps"]) && toset(keys(output.publisher_role_arns)) == toset(keys(output.ecr_repository_urls)) && toset(keys(output.github_environment_variables)) == toset(keys(output.ecr_repository_urls))
    error_message = "Exactly four services must be published; common must remain outside ECR."
  }
  assert {
    condition     = alltrue([for key, publisher in module.service_github_ecr_publisher : publisher.github_oidc_provider_arn == aws_iam_openid_connect_provider.github.arn && publisher.github_oidc_subject == "repo:${var.github_organization}@${var.github_owner_id}/${var.services[key].github_repository}@${var.services[key].github_repository_id}:environment:dev"])
    error_message = "Every service must use the shared provider and its own immutable repository identity."
  }
  assert {
    condition     = aws_iam_openid_connect_provider.github.url == "https://token.actions.githubusercontent.com" && toset(aws_iam_openid_connect_provider.github.client_id_list) == toset(["sts.amazonaws.com"])
    error_message = "The root provider must trust GitHub and the STS audience only."
  }
}
