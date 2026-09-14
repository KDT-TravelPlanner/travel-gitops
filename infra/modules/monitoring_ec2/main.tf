locals {
  name = join("-", compact([var.project_name, var.environment, var.name_suffix]))

  # Select only repository-owned profiles; callers cannot inject arbitrary
  # filesystem paths into the bootstrap or S3 upload.
  prometheus_config_path   = var.platform == "eks" ? "${path.module}/../../../monitoring/prometheus/prometheus.eks.yml" : "${path.module}/../../../monitoring/prometheus/prometheus.ec2.yml"
  prometheus_bind_address  = var.platform == "eks" ? "0.0.0.0" : "127.0.0.1"
  prometheus_runtime_flags = var.platform == "eks" ? "--config.file=/etc/prometheus/prometheus.yml --web.enable-remote-write-receiver" : "--config.file=/etc/prometheus/prometheus.yml"
  eks_dashboard_download   = var.platform == "eks" ? join("\n", [for name in ["aws-eks-load-test", "eks-msa"] : "aws s3 cp \"s3://${aws_s3_bucket.monitoring_config.id}/grafana/dashboards/${name}.json\" /etc/travel-planner/grafana/dashboards/${name}.json"]) : ""

  # Keep the EC2 bootstrap revision tied to every configuration object that
  # the instance downloads. A changed file therefore replaces the singleton
  # Monitoring EC2 instead of leaving the old configuration in place.
  monitoring_config_revision = sha256(join("|", concat([
    filemd5(local.prometheus_config_path),
    filemd5("${path.module}/../../../monitoring/loki/loki.prod.yml"),
    filemd5("${path.module}/../../../monitoring/ec2/datasources.yml"),
    filemd5("${path.module}/../../../monitoring/grafana/provisioning/dashboards/dashboards.yml"),
    filemd5("${path.module}/../../../monitoring/grafana/dashboards/backend-overview.json"),
    filemd5("${path.module}/../../../monitoring/grafana/dashboards/aws-load-test.json"),
    filemd5("${path.module}/../../../monitoring/grafana/dashboards/aws-recovery.json"),
  ], var.platform == "eks" ? [for name in ["aws-eks-load-test", "eks-msa"] : filemd5("${path.module}/../../../monitoring/grafana/dashboards/${name}.json")] : [])))
}

# ── 설정 파일용 S3 버킷 ─────────────────────────────────────────
# 지속 자원(S3 프론트, 프로필 이미지)과 다르게, 이 버킷은 설정 파일만
# 담는 용도라 force_destroy=true로 둠 (dev-runtime 생명주기: plan→apply→test→destroy)
resource "aws_s3_bucket" "monitoring_config" {
  bucket        = var.monitoring_bucket_name
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "monitoring_config" {
  bucket                  = aws_s3_bucket.monitoring_config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "monitoring_config" {
  bucket = aws_s3_bucket.monitoring_config.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "monitoring_config" {
  bucket = aws_s3_bucket.monitoring_config.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ── 기존 로컬 monitoring/ 폴더 파일들을 그대로 S3에 업로드 ──────────
# 내용을 다시 타이핑하지 않고, 이미 검증된 로컬 설정을 그대로 재사용함
resource "aws_s3_object" "prometheus_config" {
  bucket = aws_s3_bucket.monitoring_config.id
  key    = "prometheus/prometheus.yml"
  source = local.prometheus_config_path
  etag   = filemd5(local.prometheus_config_path)
}

resource "aws_s3_object" "loki_config" {
  bucket = aws_s3_bucket.monitoring_config.id
  key    = "loki/loki.yml"
  source = "${path.module}/../../../monitoring/loki/loki.prod.yml"
  etag   = filemd5("${path.module}/../../../monitoring/loki/loki.prod.yml")
}

resource "aws_s3_object" "grafana_datasources" {
  bucket = aws_s3_bucket.monitoring_config.id
  key    = "grafana/provisioning/datasources/datasources.yml"
  source = "${path.module}/../../../monitoring/ec2/datasources.yml"
  etag   = filemd5("${path.module}/../../../monitoring/ec2/datasources.yml")
}

resource "aws_s3_object" "grafana_dashboards_provisioning" {
  bucket = aws_s3_bucket.monitoring_config.id
  key    = "grafana/provisioning/dashboards/dashboards.yml"
  source = "${path.module}/../../../monitoring/grafana/provisioning/dashboards/dashboards.yml"
  etag   = filemd5("${path.module}/../../../monitoring/grafana/provisioning/dashboards/dashboards.yml")
}

resource "aws_s3_object" "grafana_dashboard_backend_overview" {
  bucket = aws_s3_bucket.monitoring_config.id
  key    = "grafana/dashboards/backend-overview.json"
  source = "${path.module}/../../../monitoring/grafana/dashboards/backend-overview.json"
  etag   = filemd5("${path.module}/../../../monitoring/grafana/dashboards/backend-overview.json")
}

# Plan04 (aws-load-test-handoff/plans/04_GRAFANA_DASHBOARD_PLAN.md): B-01 evidence
# dashboard. Its Prometheus panels reference k6 remote-write metric names that are
# not yet verified against a live receiver (D-002 not approved/wired) — see the
# dashboard JSON's own panel descriptions. CloudWatch/Loki/Spring-scrape panels use
# already-provisioned datasources and work today.
resource "aws_s3_object" "grafana_dashboard_aws_load_test" {
  bucket = aws_s3_bucket.monitoring_config.id
  key    = "grafana/dashboards/aws-load-test.json"
  source = "${path.module}/../../../monitoring/grafana/dashboards/aws-load-test.json"
  etag   = filemd5("${path.module}/../../../monitoring/grafana/dashboards/aws-load-test.json")
}

resource "aws_s3_object" "grafana_dashboard_aws_recovery" {
  bucket = aws_s3_bucket.monitoring_config.id
  key    = "grafana/dashboards/aws-recovery.json"
  source = "${path.module}/../../../monitoring/grafana/dashboards/aws-recovery.json"
  etag   = filemd5("${path.module}/../../../monitoring/grafana/dashboards/aws-recovery.json")
}

resource "aws_s3_object" "grafana_dashboard_aws_eks_load_test" {
  count  = var.platform == "eks" ? 1 : 0
  bucket = aws_s3_bucket.monitoring_config.id
  key    = "grafana/dashboards/aws-eks-load-test.json"
  source = "${path.module}/../../../monitoring/grafana/dashboards/aws-eks-load-test.json"
  etag   = filemd5("${path.module}/../../../monitoring/grafana/dashboards/aws-eks-load-test.json")
}

# ── Monitoring EC2 IAM 권한 ─────────────────────────────────────
data "aws_iam_policy_document" "instance_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  name               = "${local.name}-monitoring-runtime"
  assume_role_policy = data.aws_iam_policy_document.instance_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "monitoring_runtime" {
  statement {
    sid     = "MonitoringConfigDownload"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.monitoring_config.arn,
      "${aws_s3_bucket.monitoring_config.arn}/*",
    ]
  }

  # Prometheus EC2 Service Discovery is retained only for the legacy EC2
  # profile. EKS Alloy discovers Pods through Kubernetes RBAC instead.
  dynamic "statement" {
    for_each = var.platform == "ec2" ? [true] : []

    content {
      sid       = "PrometheusEc2Discovery"
      actions   = ["ec2:DescribeInstances"]
      resources = ["*"]
    }
  }

  # Grafana CloudWatch Data Source — 조회 전용
  statement {
    sid = "GrafanaCloudWatchDataSource"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "cloudwatch:DescribeAlarmsForMetric",
      "tag:GetResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "monitoring_runtime" {
  name   = "${local.name}-monitoring-runtime"
  role   = aws_iam_role.monitoring.id
  policy = data.aws_iam_policy_document.monitoring_runtime.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "${local.name}-monitoring-runtime"
  role = aws_iam_role.monitoring.name
  tags = var.tags
}

# ── Monitoring EC2 (ASG 아님, 단일 고정 인스턴스) ─────────────────
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "monitoring" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = var.app_subnet_id
  iam_instance_profile   = aws_iam_instance_profile.monitoring.name
  vpc_security_group_ids = [var.monitoring_security_group_id]

  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    http_tokens                 = "required"
  }

  root_block_device {
    encrypted   = true
    volume_size = var.root_volume_size_gib
    volume_type = "gp3"
  }

  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/monitoring-user-data.sh.tftpl", {
    aws_region                       = var.aws_region
    eks_dashboard_download           = local.eks_dashboard_download
    grafana_anonymous_org_role       = var.grafana_anonymous_viewer_enabled ? "Viewer" : ""
    grafana_anonymous_viewer_enabled = var.grafana_anonymous_viewer_enabled
    grafana_image_reference          = var.grafana_image_reference
    loki_image_reference             = var.loki_image_reference
    monitoring_config_revision       = local.monitoring_config_revision
    monitoring_bucket_name           = aws_s3_bucket.monitoring_config.id
    platform                         = var.platform
    prometheus_bind_address          = local.prometheus_bind_address
    prometheus_image_reference       = var.prometheus_image_reference
    prometheus_runtime_flags         = local.prometheus_runtime_flags
  })

  depends_on = [
    aws_s3_object.prometheus_config,
    aws_s3_object.loki_config,
    aws_s3_object.grafana_datasources,
    aws_s3_object.grafana_dashboards_provisioning,
    aws_s3_object.grafana_msa_dashboard,
    aws_s3_object.grafana_dashboard_backend_overview,
    aws_s3_object.grafana_dashboard_aws_load_test,
    aws_s3_object.grafana_dashboard_aws_recovery,
    aws_s3_object.grafana_dashboard_aws_eks_load_test,
  ]

  tags = merge(var.tags, {
    Name    = "${local.name}-monitoring"
    Service = "travel-planner-monitoring"
  })
}

# ── Backend EC2들이 이 Monitoring EC2를 찾을 수 있도록 주소를 SSM에 발행 ──
# EC2가 스스로 등록하는 방식이 아니라, Terraform이 aws_instance의
# private_ip를 그대로 SSM에 써두는 결정론적 방식 (더 단순하고 안전함)
resource "aws_ssm_parameter" "monitoring_endpoint" {
  name  = var.monitoring_endpoint_parameter_name
  type  = "String"
  value = aws_instance.monitoring.private_ip
  tags  = var.tags
}

resource "aws_s3_object" "grafana_msa_dashboard" {
  count  = var.platform == "eks" ? 1 : 0
  bucket = aws_s3_bucket.monitoring_config.id
  key    = "grafana/dashboards/eks-msa.json"
  source = "${path.module}/../../../monitoring/grafana/dashboards/eks-msa.json"
  etag   = filemd5("${path.module}/../../../monitoring/grafana/dashboards/eks-msa.json")
}
