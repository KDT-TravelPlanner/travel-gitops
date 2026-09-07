locals {
  name = "${var.project_name}-${var.environment}"
}

resource "aws_kms_key" "eks_secrets" {
  description         = "Envelope encryption for ${local.name} EKS Kubernetes Secrets"
  enable_key_rotation = true
  tags                = merge(var.tags, { Name = "${local.name}-eks-secrets" })
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${local.name}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.name}-eks/cluster"
  retention_in_days = var.cluster_log_retention_days
  tags              = merge(var.tags, { Name = "${local.name}-eks-cluster-logs" })
}

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = "${local.name}-eks"
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.public_access_cidrs
  }

  # API-only mode so admin_principal_arns below (Access Entries) is the sole
  # source of truth for who can authenticate — no legacy aws-auth ConfigMap.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Trivy AVD-AWS-0038/0040 baseline: every control-plane log stream on, and
  # Secrets encrypted with a dedicated (non-S3-SSE) KMS key.
  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
  }

  tags = merge(var.tags, { Name = "${local.name}-eks" })

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_cloudwatch_log_group.cluster,
  ]
}

data "tls_certificate" "cluster" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

# Bootstraps the cluster's own IRSA trust anchor only. SCRUM-11 attaches the
# actual workload roles once the backend/monitoring IRSA policies exist.
resource "aws_iam_openid_connect_provider" "cluster" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]
  tags            = var.tags
}

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Standard managed policy, not scoped to a single repository like the
# backend_service instance role: nodes must also pull EKS addon images
# (CNI, CoreDNS, kube-proxy) alongside the backend image.
resource "aws_iam_role_policy_attachment" "node_ecr_read_only" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name}-eks-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.node_instance_types
  ami_type        = "AL2023_x86_64_STANDARD"

  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  tags = merge(var.tags, {
    Name = "${local.name}-eks-nodes"
    # Cluster Autoscaler discovers only this managed node group. These tags
    # are propagated to the backing ASG by EKS and are intentionally scoped to
    # the exact dev-eks cluster name.
    "k8s.io/cluster-autoscaler/enabled"           = "true"
    "k8s.io/cluster-autoscaler/${local.name}-eks" = "owned"
  })

  lifecycle {
    precondition {
      condition     = var.node_min_size <= var.node_desired_size && var.node_desired_size <= var.node_max_size
      error_message = "node_min_size <= node_desired_size <= node_max_size must hold."
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_read_only,
  ]
}

# Kubernetes RBAC is separate from IAM: an ARN needs an explicit Access Entry
# here before kubectl works for it, no matter how much AWS-side IAM access it
# already has. Typically the team's shared SSO permission-set role — the same
# one already used for EC2 SSM access — so this list stays short.
resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = aws_eks_access_entry.admin

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
