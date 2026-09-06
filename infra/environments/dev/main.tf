locals {
  common_tags = {
    Environment = "dev"
    Project     = var.project_name
    Stack       = "msa-ecr"
  }
}

module "service_ecr" {
  source   = "../../modules/service_ecr"
  for_each = var.services

  environment     = "dev"
  service_name    = each.key
  project_name    = var.project_name
  max_image_count = var.max_image_count
  tags            = local.common_tags
}

module "github_ecr_publisher" {
  source   = "../../modules/github_ecr_publisher"
  for_each = var.services

  github_oidc_provider_arn = local.github_oidc_provider_arn
  ecr_repository_arn       = module.service_ecr[each.key].repository_arn
  service_name             = each.key
  environment              = "dev"
  github_organization      = var.github_organization
  github_owner_id          = var.github_owner_id
  github_repository        = each.value.github_repository
  github_repository_id     = each.value.github_repository_id
  github_environment       = var.github_environment
  project_name             = var.project_name
  tags                     = local.common_tags
}
