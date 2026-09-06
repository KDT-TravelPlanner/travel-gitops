# GitHub Actions OIDC provider — 계정당 하나. 모놀리스가 이미 만들었으면 참조만 한다.

data "aws_iam_openid_connect_provider" "github" {
  count = var.manage_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.manage_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # thumbprint_list 를 생략하면 AWS 가 token.actions.githubusercontent.com 의 인증서를
  # 자동 검증한다(모놀리스도 동일).
  thumbprint_list = []

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  github_oidc_provider_arn = (
    var.manage_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )
}
