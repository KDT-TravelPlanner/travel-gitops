locals {
  environment                        = "dev"
  name                               = "${var.project_name}-${local.environment}"
  monitoring_bucket_name             = "${var.project_name}-${local.environment}-eks-monitoring-config-${var.aws_account_id}"
  monitoring_endpoint_parameter_name = "/${var.project_name}/${local.environment}/eks/monitoring-endpoint"
  monitoring_bundle_prefix           = "kubernetes/monitoring"
  kustomize_root                     = abspath("${path.module}/../../../k8s")
  common_tags = {
    Environment = local.environment
    Phase       = "eks-baseline"
    Project     = var.project_name
    Stack       = "dev-eks"
  }

  # Argo CD will eventually read k8s/overlays/dev-eks directly. Before Argo
  # CD is installed, upload an immutable source snapshot under the existing
  # narrow S3 prefix so the SSM bastion can run the same staged Kustomize
  # renders. Preserve the repository-relative base/overlay layout so the
  # aggregate, platform and workload roots are all independently renderable.
  kubernetes_bundle_files = {
    for relative_path in setunion(
      fileset(local.kustomize_root, "base/**"),
      fileset(local.kustomize_root, "overlays/dev-eks/**"),
    ) : "${local.monitoring_bundle_prefix}/${relative_path}" => file("${local.kustomize_root}/${relative_path}")
  }

  automation_root = abspath("${path.module}/../../../scripts/eks")
  automation_bundle_files = {
    for relative_path in [
      "bootstrap-backend-secret.sh",
      "render-action-time.py",
      "run-dev-eks-deployment.sh",
    ] : "${local.monitoring_bundle_prefix}/scripts/eks/${relative_path}" => file("${local.automation_root}/${relative_path}")
  }
  monitoring_bundle_files = merge(local.kubernetes_bundle_files, local.automation_bundle_files)

  monitoring_bundle_hashes = {
    for key, content in local.monitoring_bundle_files :
    trimprefix(key, "${local.monitoring_bundle_prefix}/") => sha256(content)
  }
  monitoring_bundle_revision = sha256(jsonencode(local.monitoring_bundle_hashes))
  monitoring_bundle_manifest = jsonencode({
    schema_version = "dev-eks-bundle/v1"
    revision       = local.monitoring_bundle_revision
    files          = local.monitoring_bundle_hashes
  })

  # This object is intentionally metadata-only. Secret ARNs are references
  # used by the approved bootstrap; SecretString/SecretBinary values never
  # enter Terraform state through this contract.
  deployment_contract = {
    schema_version                 = "dev-eks-deployment-contract/v1"
    aws_account_id                 = var.aws_account_id
    aws_region                     = var.aws_region
    cluster_name                   = module.eks_cluster.cluster_name
    alb_security_group_id          = aws_security_group.alb.id
    bastion_instance_id            = aws_instance.bastion.id
    bundle_revision_sha256         = local.monitoring_bundle_revision
    vpc_id                         = data.terraform_remote_state.persistent.outputs.vpc_id
    public_subnet_ids              = data.terraform_remote_state.persistent.outputs.public_subnet_ids
    api_certificate_arn            = data.terraform_remote_state.persistent.outputs.api_certificate_arn
    profile_image_bucket_name      = data.terraform_remote_state.persistent.outputs.profile_image_bucket_name
    profile_image_public_base_url  = data.terraform_remote_state.persistent.outputs.profile_image_public_base_url
    backend_ecr_repository_url     = data.terraform_remote_state.persistent.outputs.backend_ecr_repository_url
    backend_application_secret_arn = data.terraform_remote_state.persistent.outputs.backend_application_secret_arn
    database_master_secret_arn     = module.backend_data.database_master_secret_arn
    redis_auth_secret_arn          = module.backend_data.redis_auth_secret_arn
  }
  deployment_contract_json = jsonencode(local.deployment_contract)
}

data "terraform_remote_state" "persistent" {
  backend = "s3"

  config = {
    bucket       = var.state_bucket
    key          = var.persistent_state_key
    region       = var.aws_region
    use_lockfile = true
    encrypt      = true
  }
}

# dev-runtime and dev-eks are intentionally sequential owners of the same
# persistent app route tables. The operator must verify dev-runtime State is
# empty before applying this State; simultaneous ownership is unsupported.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.name}-nat" })
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = data.terraform_remote_state.persistent.outputs.public_subnet_ids[0]
  tags          = merge(local.common_tags, { Name = "${local.name}-nat" })
}

resource "aws_route" "app_default" {
  for_each = toset(data.terraform_remote_state.persistent.outputs.app_route_table_ids)

  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
  route_table_id         = each.value
}

# Deliberately independent of dev-runtime: the EKS cluster and its disposable
# data tier must be creatable and destroyable after dev-runtime is empty.
module "eks_cluster" {
  source = "../../modules/eks_cluster"

  admin_principal_arns    = var.admin_principal_arns
  environment             = local.environment
  endpoint_private_access = true
  endpoint_public_access  = var.endpoint_public_access
  kubernetes_version      = var.kubernetes_version
  node_desired_size       = var.node_desired_size
  node_instance_types     = var.node_instance_types
  node_max_size           = var.node_max_size
  node_min_size           = var.node_min_size
  project_name            = var.project_name
  public_access_cidrs     = var.public_access_cidrs
  subnet_ids              = data.terraform_remote_state.persistent.outputs.app_subnet_ids
  tags                    = local.common_tags

  depends_on = [
    aws_route.app_default,
  ]
}

# The EKS-created cluster SG is deliberately kept private: it carries the
# Bastion API rule and the cluster self-rule, not public user traffic.  ALB
# owns a separate disposable SG so Cloudflare/origin clients can reach 80/443
# without opening the control-plane communication SG to the internet.
resource "aws_security_group" "alb" {
  name_prefix            = "${local.name}-alb-"
  description            = "Public ALB entry point for the disposable dev-eks Backend"
  vpc_id                 = data.terraform_remote_state.persistent.outputs.vpc_id
  revoke_rules_on_delete = true
  tags = merge(local.common_tags, {
    Name = "${local.name}-alb-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
  description       = "HTTP redirect entry point"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  ip_protocol       = "tcp"
  to_port           = 443
  description       = "Public HTTPS API traffic"
}

resource "aws_vpc_security_group_egress_rule" "alb_cluster" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = module.eks_cluster.cluster_security_group_id
  from_port                    = -1
  ip_protocol                  = "-1"
  to_port                      = -1
  description                  = "Forward ALB traffic to EKS targets"
}

# The disposable EKS runtime owns the same data tier that dev-runtime used
# for the EC2 baseline. The two roots are mutually exclusive owners; this
# root never reads dev-runtime State. Pods use the EKS cluster SG under the
# default VPC CNI model, so the data SGs allow only that SG on exact ports.
resource "aws_security_group" "database" {
  name_prefix            = "${local.name}-database-"
  description            = "Private PostgreSQL access from the dev-eks cluster SG"
  vpc_id                 = data.terraform_remote_state.persistent.outputs.vpc_id
  revoke_rules_on_delete = true
  egress                 = []
  tags                   = merge(local.common_tags, { Name = "${local.name}-database-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "database_cluster" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = module.eks_cluster.cluster_security_group_id
  from_port                    = 5432
  ip_protocol                  = "tcp"
  to_port                      = 5432
  description                  = "PostgreSQL from EKS cluster nodes only"
}

resource "aws_security_group" "cache" {
  name_prefix            = "${local.name}-cache-"
  description            = "Private TLS Redis access from the dev-eks cluster SG"
  vpc_id                 = data.terraform_remote_state.persistent.outputs.vpc_id
  revoke_rules_on_delete = true
  egress                 = []
  tags                   = merge(local.common_tags, { Name = "${local.name}-cache-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "cache_cluster" {
  security_group_id            = aws_security_group.cache.id
  referenced_security_group_id = module.eks_cluster.cluster_security_group_id
  from_port                    = 6379
  ip_protocol                  = "tcp"
  to_port                      = 6379
  description                  = "TLS Redis from EKS cluster nodes only"
}

module "backend_data" {
  source = "../../modules/backend_data"

  cache_node_type            = "cache.t4g.micro"
  cache_security_group_id    = aws_security_group.cache.id
  data_subnet_ids            = data.terraform_remote_state.persistent.outputs.data_subnet_ids
  database_name              = "travel_diary_dev"
  database_security_group_id = aws_security_group.database.id
  database_username          = "travel_planner"
  db_instance_class          = "db.t4g.micro"
  environment                = local.environment
  postgres_engine_version    = var.postgres_engine_version
  project_name               = var.project_name
  redis_engine_version       = "7.1"
  tags                       = local.common_tags

  depends_on = [
    aws_vpc_security_group_ingress_rule.database_cluster,
    aws_vpc_security_group_ingress_rule.cache_cluster,
  ]
}

# EKS Pod Identity keeps the Backend ServiceAccount free of account-specific
# annotations while granting only the persistent profile-image runtime policy.
# The exact add-on version is a required action-time input and must be queried
# for the selected EKS Kubernetes version before the saved plan.
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name  = module.eks_cluster.cluster_name
  addon_name    = "eks-pod-identity-agent"
  addon_version = var.pod_identity_agent_version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  tags                        = local.common_tags

  depends_on = [module.eks_cluster]
}

data "aws_iam_policy_document" "backend_pod_identity_assume_role" {
  statement {
    sid     = "EksPodIdentityAssumeRole"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backend_pod_identity" {
  name               = "${local.name}-backend-pod-identity"
  assume_role_policy = data.aws_iam_policy_document.backend_pod_identity_assume_role.json
  tags               = merge(local.common_tags, { Name = "${local.name}-backend-pod-identity" })
}

resource "aws_iam_role_policy_attachment" "backend_profile_image" {
  role       = aws_iam_role.backend_pod_identity.name
  policy_arn = data.terraform_remote_state.persistent.outputs.profile_image_runtime_policy_arn
}

resource "aws_eks_pod_identity_association" "backend" {
  cluster_name    = module.eks_cluster.cluster_name
  namespace       = "travel-planner"
  service_account = "backend"
  role_arn        = aws_iam_role.backend_pod_identity.arn

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy_attachment.backend_profile_image,
  ]
}

# Cluster Autoscaler is isolated from Backend and Alloy identities. Pod
# Identity keeps the ServiceAccount annotation-free while the policy below
# permits discovery and scaling only for this dev-eks managed node group.
data "aws_iam_policy_document" "cluster_autoscaler_pod_identity_assume_role" {
  statement {
    sid     = "EksPodIdentityAssumeRole"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "cluster_autoscaler_runtime" {
  statement {
    sid = "DescribeAutoscalingAndEc2"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ScaleDevEksNodeGroup"
    actions   = ["autoscaling:SetDesiredCapacity", "autoscaling:TerminateInstanceInAutoScalingGroup"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled"
      values   = ["true"]
    }

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${module.eks_cluster.cluster_name}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${local.name}-cluster-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_pod_identity_assume_role.json
  tags               = merge(local.common_tags, { Name = "${local.name}-cluster-autoscaler" })
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name   = "${local.name}-cluster-autoscaler"
  role   = aws_iam_role.cluster_autoscaler.id
  policy = data.aws_iam_policy_document.cluster_autoscaler_runtime.json
}

resource "aws_eks_pod_identity_association" "cluster_autoscaler" {
  cluster_name    = module.eks_cluster.cluster_name
  namespace       = "kube-system"
  service_account = "cluster-autoscaler"
  role_arn        = aws_iam_role.cluster_autoscaler.arn

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy.cluster_autoscaler,
  ]
}

# AWS Load Balancer Controller is kept on a separate Pod Identity role from
# Backend, Alloy and Cluster Autoscaler. Optional WAF/Shield/Cognito features
# stay disabled in the manifest, so their permissions are intentionally absent.
data "aws_iam_policy_document" "load_balancer_controller_pod_identity_assume_role" {
  statement {
    sid     = "EksPodIdentityAssumeRole"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "load_balancer_controller_runtime" {
  statement {
    sid = "CreateServiceLinkedRole"
    actions = [
      "iam:CreateServiceLinkedRole",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com"]
    }
  }

  statement {
    sid = "DescribeVpcAndLoadBalancers"
    actions = [
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeTags",
      "ec2:DescribeInstances",
      "ec2:DescribeVpcs",
      "ec2:DescribeVpcPeeringConnections",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeListenerCertificates",
      "elasticloadbalancing:DescribeListenerAttributes",
      "elasticloadbalancing:DescribeSSLPolicies",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTags",
    ]
    resources = ["*"]
  }

  statement {
    sid = "DescribeApprovedCertificates"
    actions = [
      "acm:DescribeCertificate",
      "acm:ListCertificates",
    ]
    resources = ["*"]
  }

  statement {
    sid = "CreateLoadBalancerSecurityGroups"
    actions = [
      "ec2:CreateSecurityGroup",
    ]
    resources = ["*"]
  }

  statement {
    sid = "TagLoadBalancerSecurityGroupsOnCreate"
    actions = [
      "ec2:CreateTags",
    ]
    resources = ["arn:aws:ec2:*:*:security-group/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSecurityGroup"]
    }

    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    sid = "ManageTaggedLoadBalancerSecurityGroups"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:DeleteSecurityGroup",
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
    resources = ["*"]

    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    sid = "CreateTaggedLoadBalancers"
    actions = [
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:CreateTargetGroup",
    ]
    resources = ["*"]

    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    sid = "ManageTaggedLoadBalancers"
    actions = [
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:SetIpAddressType",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyListenerAttributes",
    ]
    resources = ["*"]

    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    sid = "ManageLoadBalancerListenersAndRules"
    actions = [
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:SetRulePriorities",
      "elasticloadbalancing:AddListenerCertificates",
      "elasticloadbalancing:RemoveListenerCertificates",
    ]
    resources = ["*"]
  }

  statement {
    sid = "TagLoadBalancerResources"
    actions = [
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
    ]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*",
    ]
  }

  statement {
    sid       = "RegisterTargets"
    actions   = ["elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets"]
    resources = ["arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"]
  }
}

resource "aws_iam_role" "load_balancer_controller" {
  name               = "${local.name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.load_balancer_controller_pod_identity_assume_role.json
  tags               = merge(local.common_tags, { Name = "${local.name}-aws-load-balancer-controller" })
}

resource "aws_iam_role_policy" "load_balancer_controller" {
  name   = "${local.name}-aws-load-balancer-controller"
  role   = aws_iam_role.load_balancer_controller.id
  policy = data.aws_iam_policy_document.load_balancer_controller_runtime.json
}

resource "aws_eks_pod_identity_association" "load_balancer_controller" {
  cluster_name    = module.eks_cluster.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.load_balancer_controller.arn

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy.load_balancer_controller,
  ]
}

# ── SSM 검증 bastion ────────────────────────────────────────────
# EKS 컨트롤 플레인이 기본적으로 완전 비공개(endpoint_public_access=false)라,
# 이 프로젝트의 다른 EC2들(backend_service, monitoring_ec2)과 동일하게 인바운드
# 포트 없이 SSM으로만 접속해서 그 안에서 kubectl을 검증한다. bastion 자체가
# private app subnet 안에 있으므로 별도 포트포워딩 없이 바로 private endpoint에
# 닿는다.
data "aws_ssm_parameter" "bastion_al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_iam_policy_document" "bastion_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  name               = "${local.name}-eks-bastion"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "bastion_runtime" {
  statement {
    sid       = "DescribeEksCluster"
    actions   = ["eks:DescribeCluster"]
    resources = [module.eks_cluster.cluster_arn]
  }

  statement {
    sid       = "ListMonitoringBundle"
    actions   = ["s3:ListBucket"]
    resources = [module.monitoring_ec2.monitoring_config_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [local.monitoring_bundle_prefix, "${local.monitoring_bundle_prefix}/*"]
    }
  }

  statement {
    sid       = "ReadMonitoringBundle"
    actions   = ["s3:GetObject"]
    resources = ["${module.monitoring_ec2.monitoring_config_bucket_arn}/${local.monitoring_bundle_prefix}/*"]
  }

  statement {
    sid       = "ReadMonitoringEndpoint"
    actions   = ["ssm:GetParameter"]
    resources = [module.monitoring_ec2.monitoring_endpoint_parameter_arn]
  }

  statement {
    sid     = "ReadBackendRuntimeSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      data.terraform_remote_state.persistent.outputs.backend_application_secret_arn,
      module.backend_data.database_master_secret_arn,
      module.backend_data.redis_auth_secret_arn,
    ]
  }

  # The private Monitoring EC2 is part of this disposable State. The
  # verification bastion may run the read-only diagnostics needed to prove
  # Prometheus/Loki readiness, but only against this exact instance and the
  # AWS-RunShellScript document. The permission disappears with dev-eks.
  statement {
    sid     = "RunMonitoringDiagnostics"
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
      "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/${module.monitoring_ec2.instance_id}",
    ]
  }
}

resource "aws_iam_role_policy" "bastion_runtime" {
  name   = "${local.name}-eks-bastion-runtime"
  role   = aws_iam_role.bastion.id
  policy = data.aws_iam_policy_document.bastion_runtime.json
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${local.name}-eks-bastion"
  role = aws_iam_role.bastion.name
  tags = local.common_tags
}

resource "aws_eks_access_entry" "bastion" {
  cluster_name  = module.eks_cluster.cluster_name
  principal_arn = aws_iam_role.bastion.arn
  type          = "STANDARD"
  tags          = local.common_tags
}

resource "aws_eks_access_policy_association" "bastion" {
  cluster_name  = module.eks_cluster.cluster_name
  principal_arn = aws_iam_role.bastion.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [
    aws_eks_access_entry.bastion,
  ]
}

resource "aws_security_group" "bastion" {
  name_prefix            = "${local.name}-eks-bastion-"
  description            = "SSM-only EKS verification bastion; no inbound"
  vpc_id                 = data.terraform_remote_state.persistent.outputs.vpc_id
  revoke_rules_on_delete = true
  tags                   = merge(local.common_tags, { Name = "${local.name}-eks-bastion-sg" })
}

resource "aws_vpc_security_group_egress_rule" "bastion_https" {
  security_group_id = aws_security_group.bastion.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  ip_protocol       = "tcp"
  to_port           = 443
  description       = "SSM and AWS API endpoints"
}

resource "aws_vpc_security_group_egress_rule" "bastion_dns_udp" {
  security_group_id = aws_security_group.bastion.id
  cidr_ipv4         = "${cidrhost(data.terraform_remote_state.persistent.outputs.vpc_cidr, 2)}/32"
  from_port         = 53
  ip_protocol       = "udp"
  to_port           = 53
  description       = "DNS resolution"
}

resource "aws_vpc_security_group_egress_rule" "bastion_dns_tcp" {
  security_group_id = aws_security_group.bastion.id
  cidr_ipv4         = "${cidrhost(data.terraform_remote_state.persistent.outputs.vpc_cidr, 2)}/32"
  from_port         = 53
  ip_protocol       = "tcp"
  to_port           = 53
  description       = "DNS fallback"
}

# EKS's auto-created cluster security group has no rule allowing anything in
# by default; the bastion needs one explicit path to the private API port.
resource "aws_vpc_security_group_ingress_rule" "cluster_from_bastion" {
  security_group_id            = module.eks_cluster.cluster_security_group_id
  referenced_security_group_id = aws_security_group.bastion.id
  from_port                    = 443
  ip_protocol                  = "tcp"
  to_port                      = 443
  description                  = "kubectl from the SSM verification bastion only"
}

resource "aws_security_group" "monitoring" {
  name_prefix            = "${local.name}-monitoring-"
  description            = "Private EKS Monitoring EC2; ingress is only from the EKS cluster security group"
  vpc_id                 = data.terraform_remote_state.persistent.outputs.vpc_id
  revoke_rules_on_delete = true
  tags                   = merge(local.common_tags, { Name = "${local.name}-monitoring-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_prometheus" {
  security_group_id            = aws_security_group.monitoring.id
  referenced_security_group_id = module.eks_cluster.cluster_security_group_id
  from_port                    = 9090
  ip_protocol                  = "tcp"
  to_port                      = 9090
  description                  = "EKS Alloy remote-write receiver only"
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_loki" {
  security_group_id            = aws_security_group.monitoring.id
  referenced_security_group_id = module.eks_cluster.cluster_security_group_id
  from_port                    = 3100
  ip_protocol                  = "tcp"
  to_port                      = 3100
  description                  = "EKS Alloy log push only"
}

resource "aws_vpc_security_group_egress_rule" "monitoring_https" {
  security_group_id = aws_security_group.monitoring.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  ip_protocol       = "tcp"
  to_port           = 443
  description       = "DockerHub and AWS API egress through the dev-eks NAT"
}

resource "aws_vpc_security_group_egress_rule" "monitoring_dns_udp" {
  security_group_id = aws_security_group.monitoring.id
  cidr_ipv4         = "${cidrhost(data.terraform_remote_state.persistent.outputs.vpc_cidr, 2)}/32"
  from_port         = 53
  ip_protocol       = "udp"
  to_port           = 53
  description       = "VPC resolver DNS"
}

resource "aws_vpc_security_group_egress_rule" "monitoring_dns_tcp" {
  security_group_id = aws_security_group.monitoring.id
  cidr_ipv4         = "${cidrhost(data.terraform_remote_state.persistent.outputs.vpc_cidr, 2)}/32"
  from_port         = 53
  ip_protocol       = "tcp"
  to_port           = 53
  description       = "VPC resolver DNS fallback"
}

module "monitoring_ec2" {
  source = "../../modules/monitoring_ec2"

  app_subnet_id                      = data.terraform_remote_state.persistent.outputs.app_subnet_ids[0]
  aws_region                         = var.aws_region
  environment                        = local.environment
  grafana_anonymous_viewer_enabled   = var.grafana_anonymous_viewer_enabled
  grafana_image_reference            = var.monitoring_image_references.grafana
  loki_image_reference               = var.monitoring_image_references.loki
  monitoring_bucket_name             = local.monitoring_bucket_name
  monitoring_endpoint_parameter_name = local.monitoring_endpoint_parameter_name
  monitoring_security_group_id       = aws_security_group.monitoring.id
  name_suffix                        = "eks"
  platform                           = "eks"
  project_name                       = var.project_name
  prometheus_image_reference         = var.monitoring_image_references.prometheus
  tags                               = local.common_tags

  depends_on = [
    aws_route.app_default,
  ]
}

resource "aws_route53_zone" "private" {
  name    = "dev-eks.kdt-travelplanner.internal"
  comment = "Private disposable dev-eks service endpoints"

  vpc {
    vpc_id     = data.terraform_remote_state.persistent.outputs.vpc_id
    vpc_region = var.aws_region
  }

  tags = merge(local.common_tags, { Name = "${local.name}-private-zone" })
}

resource "aws_route53_record" "database" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "postgres.dev-eks.kdt-travelplanner.internal"
  type    = "CNAME"
  ttl     = 30
  records = [module.backend_data.database_address]
}

resource "aws_route53_record" "redis" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "redis.dev-eks.kdt-travelplanner.internal"
  type    = "CNAME"
  ttl     = 30
  records = [module.backend_data.redis_primary_endpoint]
}

resource "aws_route53_record" "monitoring" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "monitoring.dev-eks.kdt-travelplanner.internal"
  type    = "A"
  ttl     = 30
  records = [module.monitoring_ec2.private_ip]
}

resource "aws_s3_object" "monitoring_bundle" {
  for_each = local.monitoring_bundle_files

  bucket       = module.monitoring_ec2.monitoring_config_bucket_name
  key          = each.key
  content      = each.value
  content_type = endswith(each.key, ".md") ? "text/markdown" : endswith(each.key, ".json") ? "application/json" : endswith(each.key, ".sh") ? "text/x-shellscript" : endswith(each.key, ".py") ? "text/x-python" : "application/yaml"
  etag         = md5(each.value)
}

resource "aws_s3_object" "monitoring_bundle_manifest" {
  bucket       = module.monitoring_ec2.monitoring_config_bucket_name
  key          = "${local.monitoring_bundle_prefix}/bundle-manifest.json"
  content      = local.monitoring_bundle_manifest
  content_type = "application/json"
  etag         = md5(local.monitoring_bundle_manifest)
}

resource "aws_s3_object" "deployment_contract" {
  bucket       = module.monitoring_ec2.monitoring_config_bucket_name
  key          = "${local.monitoring_bundle_prefix}/runtime-contract.json"
  content      = local.deployment_contract_json
  content_type = "application/json"
  etag         = md5(local.deployment_contract_json)

  depends_on = [
    aws_s3_object.monitoring_bundle_manifest,
  ]
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ssm_parameter.bastion_al2023_ami.value
  instance_type          = "t3.micro"
  subnet_id              = data.terraform_remote_state.persistent.outputs.app_subnet_ids[0]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  vpc_security_group_ids = [aws_security_group.bastion.id]

  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
    http_tokens                 = "required"
  }

  root_block_device {
    encrypted   = true
    volume_size = 8
    volume_type = "gp3"
  }

  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/bastion-user-data.sh.tftpl", {
    aws_region      = var.aws_region
    kubectl_version = var.bastion_kubectl_version
  })

  depends_on = [
    aws_route.app_default,
    aws_iam_role_policy.bastion_runtime,
    aws_iam_role_policy_attachment.bastion_ssm,
  ]

  tags = merge(local.common_tags, { Name = "${local.name}-eks-bastion" })
}
