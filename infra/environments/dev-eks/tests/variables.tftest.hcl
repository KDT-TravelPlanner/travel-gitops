mock_provider "aws" {
  override_during = plan

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Principal\":{\"Service\":\"eks.amazonaws.com\"}}]}"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:ap-northeast-2:123456789012:key/12345678-1234-1234-1234-123456789012"
      key_id = "12345678-1234-1234-1234-123456789012"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn  = "arn:aws:iam::123456789012:role/kdt-travelplanner-dev-eks-cluster"
      name = "kdt-travelplanner-dev-eks-cluster"
    }
  }

  mock_resource "aws_eks_cluster" {
    defaults = {
      arn      = "arn:aws:eks:ap-northeast-2:123456789012:cluster/kdt-travelplanner-dev-eks"
      endpoint = "https://EXAMPLE.gr7.ap-northeast-2.eks.amazonaws.com"
      identity = [{
        oidc = [{
          issuer = "https://oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"
        }]
      }]
      certificate_authority = [{
        data = "LS0tLS1CRUdJTi0tLS0t"
      }]
    }
  }

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"
    }
  }

  mock_resource "aws_eks_node_group" {
    defaults = {
      arn    = "arn:aws:eks:ap-northeast-2:123456789012:nodegroup/kdt-travelplanner-dev-eks/kdt-travelplanner-dev-eks-nodes/abcd1234"
      status = "ACTIVE"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
    }
  }

  mock_resource "aws_instance" {
    defaults = {
      id = "i-0123456789abcdef0"
    }
  }

  mock_resource "aws_eip" {
    defaults = {
      id        = "eipalloc-0123456789abcdef0"
      public_ip = "198.51.100.10"
    }
  }

  mock_resource "aws_nat_gateway" {
    defaults = {
      id = "nat-0123456789abcdef0"
    }
  }

  mock_resource "aws_route" {
    defaults = {
      id = "r-0123456789abcdef0"
    }
  }

  mock_resource "aws_security_group" {
    defaults = {
      id = "sg-0123456789abcdef0"
    }
  }

  mock_resource "aws_db_subnet_group" {
    defaults = {
      id   = "kdt-travelplanner-dev-database"
      name = "kdt-travelplanner-dev-database"
    }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      address    = "database.internal"
      arn        = "arn:aws:rds:ap-northeast-2:123456789012:db:kdt-travelplanner-dev-postgres"
      db_name    = "travel_diary_dev"
      id         = "kdt-travelplanner-dev-postgres"
      identifier = "kdt-travelplanner-dev-postgres"
      port       = 5432
      master_user_secret = [{
        kms_key_id    = "kms-key"
        secret_arn    = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:rds"
        secret_status = "active"
      }]
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:kdt-travelplanner-dev-redis-auth"
      id  = "kdt-travelplanner-dev-redis-auth"
    }
  }

  mock_resource "aws_secretsmanager_secret_version" {
    defaults = {
      version_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_elasticache_subnet_group" {
    defaults = {
      id   = "kdt-travelplanner-dev-cache"
      name = "kdt-travelplanner-dev-cache"
    }
  }

  mock_resource "aws_elasticache_user" {
    defaults = {
      arn       = "arn:aws:elasticache:ap-northeast-2:123456789012:user:kdt-travelplanner-dev-loadtest"
      id        = "kdt-travelplanner-dev-loadtest"
      user_id   = "kdt-travelplanner-dev-loadtest"
      user_name = "kdt-travelplanner-dev-loadtest"
    }
  }

  mock_resource "aws_elasticache_user_group" {
    defaults = {
      arn = "arn:aws:elasticache:ap-northeast-2:123456789012:usergroup:kdt-travelplanner-dev-redis-users"
      id  = "kdt-travelplanner-dev-redis-users"
    }
  }

  mock_resource "aws_elasticache_replication_group" {
    defaults = {
      arn                      = "arn:aws:elasticache:ap-northeast-2:123456789012:replicationgroup:kdt-travelplanner-dev-redis"
      id                       = "kdt-travelplanner-dev-redis"
      member_clusters          = ["kdt-travelplanner-dev-redis-001"]
      port                     = 6379
      primary_endpoint_address = "redis.internal"
    }
  }

  mock_resource "aws_eks_addon" {
    defaults = {
      addon_version = "v1.4.0-eksbuild.1"
      arn           = "arn:aws:eks:ap-northeast-2:123456789012:addon/kdt-travelplanner-dev-eks/eks-pod-identity-agent/abcd1234"
      id            = "kdt-travelplanner-dev-eks:eks-pod-identity-agent"
      status        = "ACTIVE"
    }
  }

  mock_resource "aws_eks_pod_identity_association" {
    defaults = {
      association_arn = "arn:aws:eks:ap-northeast-2:123456789012:podidentityassociation/kdt-travelplanner-dev-eks/a1b2c3d4"
      association_id  = "a1b2c3d4"
      id              = "kdt-travelplanner-dev-eks/a1b2c3d4"
    }
  }

  mock_resource "aws_route53_zone" {
    defaults = {
      id      = "ZDEVEXAMPLE"
      name    = "dev-eks.kdt-travelplanner.internal."
      zone_id = "ZDEVEXAMPLE"
    }
  }

  mock_resource "aws_route53_record" {
    defaults = {
      fqdn = "endpoint.dev-eks.kdt-travelplanner.internal."
      id   = "ZDEVEXAMPLE_endpoint_CNAME"
    }
  }
}

mock_provider "tls" {
  mock_data "tls_certificate" {
    defaults = {
      certificates = [{
        sha1_fingerprint = "9e99a48a9960b14926bb7f3b02e22da2b0ab7280"
      }]
    }
  }
}

mock_provider "random" {
  mock_resource "random_password" {
    defaults = {
      result = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZab"
    }
  }
}

override_data {
  target = data.terraform_remote_state.persistent
  values = {
    outputs = {
      app_subnet_ids                   = ["subnet-app-a", "subnet-app-b"]
      app_route_table_ids              = ["rtb-app-a", "rtb-app-b"]
      data_subnet_ids                  = ["subnet-data-a", "subnet-data-c"]
      backend_application_secret_arn   = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:kdt-travelplanner-dev-backend"
      profile_image_runtime_policy_arn = "arn:aws:iam::123456789012:policy/kdt-travelplanner-dev-profile-image-runtime"
      profile_image_bucket_name        = "kdt-travelplanner-dev-profile-images"
      profile_image_public_base_url    = "https://images.example.test"
      api_certificate_arn              = "arn:aws:acm:ap-northeast-2:123456789012:certificate/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      backend_ecr_repository_url       = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/kdt-travelplanner-dev-backend"
      public_subnet_ids                = ["subnet-public-a", "subnet-public-b"]
      vpc_id                           = "vpc-12345678"
      vpc_cidr                         = "10.20.0.0/16"
    }
  }
}

variables {
  aws_account_id             = "123456789012"
  aws_region                 = "ap-northeast-2"
  postgres_engine_version    = "17.10"
  pod_identity_agent_version = "v1.4.0-eksbuild.1"
  state_bucket               = "kdt-travelplanner-tfstate-123456789012-ap-northeast-2"
}

run "defaults_produce_expected_cluster_and_node_names" {
  command = plan

  assert {
    condition = (
      module.eks_cluster.cluster_name == "kdt-travelplanner-dev-eks" &&
      module.eks_cluster.node_group_name == "kdt-travelplanner-dev-eks-nodes" &&
      output.target_persistent_state_key == var.persistent_state_key
    )
    error_message = "dev-eks must name resources from project_name/environment and read only the configured persistent dev State key (never dev-runtime)."
  }
}

run "dev_eks_owns_nat_and_every_app_default_route" {
  command = plan

  assert {
    condition = (
      aws_eip.nat.id != null &&
      aws_nat_gateway.this.id != null &&
      length(aws_route.app_default) == 2 &&
      alltrue([for route in aws_route.app_default : route.destination_cidr_block == "0.0.0.0/0"]) &&
      alltrue([for route in aws_route.app_default : route.nat_gateway_id == aws_nat_gateway.this.id])
    )
    error_message = "dev-eks must own one NAT and one default route for every persistent app route table."
  }
}

run "data_plane_matches_ec2_baseline_and_cluster_sg_only" {
  command = plan

  assert {
    condition = (
      module.backend_data.database_name == "travel_diary_dev" &&
      module.backend_data.database_port == 5432 &&
      module.backend_data.redis_port == 6379 &&
      aws_vpc_security_group_ingress_rule.database_cluster.from_port == 5432 &&
      aws_vpc_security_group_ingress_rule.database_cluster.to_port == 5432 &&
      aws_vpc_security_group_ingress_rule.database_cluster.referenced_security_group_id == module.eks_cluster.cluster_security_group_id &&
      aws_vpc_security_group_ingress_rule.cache_cluster.from_port == 6379 &&
      aws_vpc_security_group_ingress_rule.cache_cluster.to_port == 6379 &&
      aws_vpc_security_group_ingress_rule.cache_cluster.referenced_security_group_id == module.eks_cluster.cluster_security_group_id
    )
    error_message = "dev-eks must reproduce the EC2 RDS/Redis contract and allow data ingress only from the EKS cluster SG on 5432/6379."
  }

  assert {
    condition = (
      output.database_security_group_id == aws_security_group.database.id &&
      output.cache_security_group_id == aws_security_group.cache.id &&
      output.database_master_secret_arn == module.backend_data.database_master_secret_arn &&
      output.redis_auth_secret_arn == module.backend_data.redis_auth_secret_arn
    )
    error_message = "dev-eks must expose data SG and Secret outputs for the load-test and external Backend Secret contracts."
  }
}

run "invalid_postgres_patch_is_rejected" {
  command = plan

  variables {
    postgres_engine_version = "16.4"
  }

  expect_failures = [var.postgres_engine_version]
}

run "backend_identity_and_private_dns_are_pinned" {
  command = plan

  assert {
    condition = (
      aws_eks_addon.pod_identity_agent.addon_name == "eks-pod-identity-agent" &&
      aws_eks_addon.pod_identity_agent.addon_version == var.pod_identity_agent_version &&
      aws_eks_pod_identity_association.backend.namespace == "travel-planner" &&
      aws_eks_pod_identity_association.backend.service_account == "backend" &&
      aws_iam_role_policy_attachment.backend_profile_image.policy_arn == data.terraform_remote_state.persistent.outputs.profile_image_runtime_policy_arn
    )
    error_message = "Backend must use the pinned Pod Identity add-on/association and only the persistent profile-image runtime policy."
  }

  assert {
    condition = (
      aws_route53_zone.private.name == "dev-eks.kdt-travelplanner.internal" &&
      aws_route53_record.database.type == "CNAME" &&
      aws_route53_record.redis.type == "CNAME" &&
      aws_route53_record.monitoring.type == "A"
    )
    error_message = "RDS, Redis and Monitoring must receive stable private DNS records in the dev-eks private zone."
  }
}

run "cluster_autoscaler_identity_and_discovery_are_isolated" {
  command = plan

  assert {
    condition = (
      aws_eks_pod_identity_association.cluster_autoscaler.namespace == "kube-system" &&
      aws_eks_pod_identity_association.cluster_autoscaler.service_account == "cluster-autoscaler" &&
      output.cluster_autoscaler_discovery_tags["k8s.io/cluster-autoscaler/enabled"] == "true" &&
      output.cluster_autoscaler_discovery_tags["k8s.io/cluster-autoscaler/kdt-travelplanner-dev-eks"] == "owned"
    )
    error_message = "Cluster Autoscaler must use its own Pod Identity association and exact dev-eks node-group discovery tags."
  }
}

run "load_balancer_controller_identity_isolated_and_optional_features_absent" {
  command = plan

  assert {
    condition = (
      aws_eks_pod_identity_association.load_balancer_controller.namespace == "kube-system" &&
      aws_eks_pod_identity_association.load_balancer_controller.service_account == "aws-load-balancer-controller" &&
      !strcontains(data.aws_iam_policy_document.load_balancer_controller_runtime.json, "wafv2:") &&
      !strcontains(data.aws_iam_policy_document.load_balancer_controller_runtime.json, "shield:")
    )
    error_message = "AWS Load Balancer Controller must use its own Pod Identity role without optional WAF/Shield permissions."
  }
}

run "invalid_account_id_is_rejected" {
  command = plan

  variables {
    aws_account_id = "not-an-account-id"
  }

  expect_failures = [var.aws_account_id]
}

run "invalid_kubernetes_version_is_rejected" {
  command = plan

  variables {
    kubernetes_version = "1.3"
  }

  expect_failures = [var.kubernetes_version]
}

run "cluster_is_private_by_default_with_no_admin_entries" {
  command = plan

  assert {
    condition     = !var.endpoint_public_access
    error_message = "dev-eks must default to a private-only control plane; public access is an explicit, temporary opt-in."
  }

  assert {
    condition     = length(module.eks_cluster.admin_access_entry_principal_arns) == 0
    error_message = "Without admin_principal_arns set, no Access Entries should exist."
  }

  assert {
    condition     = aws_instance.bastion.id != null
    error_message = "The SSM verification bastion must be planned so operators can kubectl in without a public endpoint."
  }
}

run "fresh_plan_uses_the_planned_bastion_identity" {
  command = plan

  assert {
    condition = (
      aws_instance.bastion.id != null &&
      jsondecode(local.deployment_contract_json).bastion_instance_id == aws_instance.bastion.id
    )
    error_message = "A fresh empty-State dev-eks plan must derive the deployment contract from the Bastion it creates, not from a pre-existing data lookup."
  }
}

run "monitoring_sg_is_private_and_cluster_scoped" {
  command = plan

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.monitoring_prometheus.from_port == 9090 &&
      aws_vpc_security_group_ingress_rule.monitoring_prometheus.to_port == 9090 &&
      aws_vpc_security_group_ingress_rule.monitoring_prometheus.referenced_security_group_id == module.eks_cluster.cluster_security_group_id &&
      aws_vpc_security_group_ingress_rule.monitoring_loki.from_port == 3100 &&
      aws_vpc_security_group_ingress_rule.monitoring_loki.referenced_security_group_id == module.eks_cluster.cluster_security_group_id &&
      aws_instance.bastion.associate_public_ip_address == false &&
      module.monitoring_ec2.private_ip != null
    )
    error_message = "Monitoring and bastion instances must be private; only the EKS cluster SG may reach 9090/3100."
  }
}

run "eks_monitoring_names_and_endpoint_are_unique" {
  command = plan

  assert {
    condition = (
      local.monitoring_bucket_name == "kdt-travelplanner-dev-eks-monitoring-config-123456789012" &&
      local.monitoring_endpoint_parameter_name == "/kdt-travelplanner/dev/eks/monitoring-endpoint"
    )
    error_message = "dev-eks Monitoring bucket, endpoint path and bastion role must be environment-unique."
  }
}

run "monitoring_bundle_is_uploaded_under_the_narrow_prefix" {
  command = plan

  assert {
    condition = (
      contains(keys(aws_s3_object.monitoring_bundle), "kubernetes/monitoring/overlays/dev-eks/kustomization.yaml") &&
      contains(keys(aws_s3_object.monitoring_bundle), "kubernetes/monitoring/base/monitoring/alloy-daemonset.yaml") &&
      contains(keys(aws_s3_object.monitoring_bundle), "kubernetes/monitoring/base/backend/deployment.yaml") &&
      contains(keys(aws_s3_object.monitoring_bundle), "kubernetes/monitoring/overlays/dev-eks/platform/kustomization.yaml") &&
      contains(keys(aws_s3_object.monitoring_bundle), "kubernetes/monitoring/overlays/dev-eks/workload/backend-configmap.patch.yaml") &&
      contains(keys(aws_s3_object.monitoring_bundle), "kubernetes/monitoring/overlays/dev-eks/README.md") &&
      contains(keys(aws_s3_object.monitoring_bundle), "kubernetes/monitoring/scripts/eks/run-dev-eks-deployment.sh") &&
      contains(keys(aws_s3_object.monitoring_bundle), "kubernetes/monitoring/scripts/eks/render-action-time.py") &&
      aws_s3_object.monitoring_bundle_manifest.key == "kubernetes/monitoring/bundle-manifest.json" &&
      !contains(keys(aws_s3_object.monitoring_bundle), "kubernetes/monitoring/monitoring-endpoint-configmap.yaml")
    )
    error_message = "dev-eks must upload the source-of-truth Backend/metrics overlay snapshot under kubernetes/monitoring only."
  }
}

run "deployment_contract_is_non_secret_and_private" {
  command = plan

  assert {
    condition = (
      aws_s3_object.deployment_contract.key == "kubernetes/monitoring/runtime-contract.json" &&
      output.deployment_contract_s3_key == aws_s3_object.deployment_contract.key &&
      output.deployment_contract_sha256 != null &&
      strcontains(aws_s3_object.deployment_contract.content, "dev-eks-deployment-contract/v1") &&
      strcontains(aws_s3_object.deployment_contract.content, "backend_ecr_repository_url") &&
      output.backend_ecr_repository_url == data.terraform_remote_state.persistent.outputs.backend_ecr_repository_url &&
      !strcontains(aws_s3_object.deployment_contract.content, "SecretString") &&
      !strcontains(aws_s3_object.deployment_contract.content, "SecretBinary") &&
      !strcontains(aws_s3_object.deployment_contract.content, "password")
    )
    error_message = "The private runtime contract must contain only metadata and Secret ARNs, never secret values."
  }
}

run "admin_principal_arns_flow_into_access_entries" {
  command = plan

  variables {
    admin_principal_arns = ["arn:aws:iam::123456789012:role/kdt-travel-terraform"]
  }

  assert {
    condition = (
      length(module.eks_cluster.admin_access_entry_principal_arns) == 1 &&
      module.eks_cluster.admin_access_entry_principal_arns[0] == "arn:aws:iam::123456789012:role/kdt-travel-terraform"
    )
    error_message = "admin_principal_arns must flow through to the eks_cluster module's Access Entries."
  }
}
