# SCRUM-127: One account-level GitHub provider shared by legacy, frontend,
# and four service publisher roles. EKS IRSA uses its own cluster provider.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = local.common_tags

  lifecycle {
    prevent_destroy = true
  }
}

# Preserve the existing remote object when extracting it from the publisher.
moved {
  from = module.github_ecr_publisher.aws_iam_openid_connect_provider.github
  to   = aws_iam_openid_connect_provider.github
}
