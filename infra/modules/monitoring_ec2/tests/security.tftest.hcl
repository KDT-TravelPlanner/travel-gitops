mock_provider "aws" {
  override_during = plan

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
    }
  }

  mock_resource "aws_instance" {
    defaults = {
      id         = "i-0123456789abcdef0"
      private_ip = "10.0.1.53"
    }
  }

  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::test-monitoring-config"
      id  = "test-monitoring-config"
    }
  }
}

override_data {
  target = data.aws_iam_policy_document.instance_assume_role
  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"ec2.amazonaws.com\"}}]}"
  }
}

variables {
  app_subnet_id                      = "subnet-app-a"
  aws_region                         = "ap-northeast-2"
  environment                        = "dev"
  name_suffix                        = ""
  platform                           = "ec2"
  grafana_image_reference            = "grafana/grafana:13.1.0"
  loki_image_reference               = "grafana/loki:3.7.2"
  monitoring_bucket_name             = "kdt-travelplanner-dev-monitoring-config-123456789012"
  monitoring_endpoint_parameter_name = "/kdt-travelplanner/dev/monitoring-endpoint"
  monitoring_security_group_id       = "sg-monitoring"
  prometheus_image_reference         = "prom/prometheus:v3.13.1"
  project_name                       = "kdt-travelplanner"
}

run "monitoring_ec2_is_private_and_encrypted" {
  command = plan

  assert {
    condition = (
      !aws_instance.monitoring.associate_public_ip_address &&
      aws_instance.monitoring.metadata_options[0].http_tokens == "required" &&
      aws_instance.monitoring.metadata_options[0].http_put_response_hop_limit == 2 &&
      aws_instance.monitoring.root_block_device[0].encrypted &&
      aws_instance.monitoring.root_block_device[0].volume_type == "gp3" &&
      aws_instance.monitoring.user_data_replace_on_change &&
      startswith(aws_instance.monitoring.user_data, "#!/usr/bin/env bash") &&
      strcontains(aws_instance.monitoring.user_data, "Terraform monitoring-config-revision:") &&
      strcontains(aws_instance.monitoring.user_data, output.monitoring_config_revision) &&
      strcontains(aws_instance.monitoring.user_data, var.prometheus_image_reference) &&
      strcontains(aws_instance.monitoring.user_data, var.loki_image_reference) &&
      strcontains(aws_instance.monitoring.user_data, var.grafana_image_reference) &&
      strcontains(aws_instance.monitoring.user_data, "--publish 3100:3100") &&
      strcontains(aws_instance.monitoring.user_data, "GF_AUTH_ANONYMOUS_ENABLED=false") &&
      strcontains(aws_instance.monitoring.user_data, "GF_AUTH_ANONYMOUS_ORG_ROLE=") &&
      strcontains(aws_instance.monitoring.user_data, "--config.file=/etc/prometheus/prometheus.yml") &&
      strcontains(aws_instance.monitoring.user_data, "127.0.0.1:9090:9090") &&
      !strcontains(aws_instance.monitoring.user_data, "web.enable-remote-write-receiver") &&
      !strcontains(aws_instance.monitoring.user_data, ":latest")
    )
    error_message = "Monitoring EC2 must have no public IP, require IMDSv2, use encrypted gp3 storage, publish Loki on host port 3100 for private Backend Alloy pushes, replace on user-data changes and run pinned monitoring images."
  }

  assert {
    condition     = !strcontains(aws_instance.monitoring.user_data, "GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer")
    error_message = "Grafana anonymous Viewer access must remain disabled by default."
  }

  assert {
    condition     = aws_ssm_parameter.monitoring_endpoint.name == var.monitoring_endpoint_parameter_name
    error_message = "Monitoring endpoint must be published under the agreed SSM parameter path."
  }

  assert {
    condition     = output.monitoring_endpoint_parameter_name == var.monitoring_endpoint_parameter_name
    error_message = "Monitoring endpoint parameter name must be exposed for narrow downstream dependencies."
  }

  assert {
    condition     = length(output.monitoring_config_revision) == 64
    error_message = "Monitoring configuration revision must be a SHA-256 hash of the uploaded configuration files."
  }

  assert {
    condition = (
      aws_s3_object.grafana_dashboard_aws_load_test.bucket == aws_s3_bucket.monitoring_config.id &&
      aws_s3_object.grafana_dashboard_aws_load_test.key == "grafana/dashboards/aws-load-test.json" &&
      strcontains(aws_instance.monitoring.user_data, "grafana/dashboards/aws-load-test.json")
    )
    error_message = "B-01 evidence dashboard must be uploaded under the provisioned dashboards path and downloaded by the Monitoring EC2 bootstrap script."
  }
}

run "monitoring_config_bucket_blocks_public_access" {
  command = plan

  assert {
    condition = (
      aws_s3_bucket_public_access_block.monitoring_config.block_public_acls &&
      aws_s3_bucket_public_access_block.monitoring_config.block_public_policy &&
      aws_s3_bucket_public_access_block.monitoring_config.ignore_public_acls &&
      aws_s3_bucket_public_access_block.monitoring_config.restrict_public_buckets
    )
    error_message = "Monitoring config bucket must block all public access."
  }
}

run "latest_monitoring_image_is_rejected" {
  command = plan

  variables {
    prometheus_image_reference = "prom/prometheus:latest"
  }

  expect_failures = [var.prometheus_image_reference]
}

run "tagless_loki_and_grafana_images_are_rejected" {
  command = plan

  variables {
    loki_image_reference    = "grafana/loki"
    grafana_image_reference = "grafana/grafana:latest"
  }

  expect_failures = [
    var.loki_image_reference,
    var.grafana_image_reference,
  ]
}

run "eks_profile_is_unique_and_receives_remote_writes" {
  command = plan

  variables {
    name_suffix                        = "eks"
    platform                           = "eks"
    monitoring_bucket_name             = "kdt-travelplanner-dev-eks-monitoring-config-123456789012"
    monitoring_endpoint_parameter_name = "/kdt-travelplanner/dev/eks/monitoring-endpoint"
  }

  assert {
    condition = (
      aws_iam_role.monitoring.name == "kdt-travelplanner-dev-eks-monitoring-runtime" &&
      aws_iam_instance_profile.monitoring.name == "kdt-travelplanner-dev-eks-monitoring-runtime" &&
      strcontains(aws_instance.monitoring.user_data, "--publish 0.0.0.0:9090:9090") &&
      strcontains(aws_instance.monitoring.user_data, "--config.file=/etc/prometheus/prometheus.yml") &&
      strcontains(aws_instance.monitoring.user_data, "--web.enable-remote-write-receiver") &&
      strcontains(aws_instance.monitoring.user_data, "aws-eks-load-test.json") &&
      !strcontains(aws_instance.monitoring.user_data, "127.0.0.1:9090:9090")
    )
    error_message = "The EKS profile must use unique names, expose Prometheus remote-write on the private SG, download the EKS dashboard, and omit EC2 discovery IAM."
  }

  assert {
    condition = (
      aws_s3_object.grafana_dashboard_aws_eks_load_test[0].key == "grafana/dashboards/aws-eks-load-test.json" &&
      length(output.monitoring_config_revision) == 64
    )
    error_message = "The EKS dashboard must be part of the EKS configuration revision and bucket."
  }
}

run "anonymous_viewer_is_action_time_only" {
  command = plan

  variables {
    grafana_anonymous_viewer_enabled = true
  }

  assert {
    condition = (
      strcontains(aws_instance.monitoring.user_data, "GF_AUTH_ANONYMOUS_ENABLED=true") &&
      strcontains(aws_instance.monitoring.user_data, "GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer") &&
      strcontains(aws_instance.monitoring.user_data, "--publish 127.0.0.1:3000:3000")
    )
    error_message = "Anonymous Viewer must be an explicit action-time option and remain loopback-bound."
  }
}
