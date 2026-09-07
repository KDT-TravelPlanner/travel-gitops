mock_provider "aws" {
  mock_resource "aws_db_instance" {
    defaults = {
      address = "database.internal"
      db_name = "travel_diary_dev"
      port    = 5432
      master_user_secret = [{
        kms_key_id    = "kms-key"
        secret_arn    = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:rds"
        secret_status = "active"
      }]
    }
  }

  mock_resource "aws_elasticache_replication_group" {
    defaults = {
      port                     = 6379
      primary_endpoint_address = "redis.internal"
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

variables {
  cache_security_group_id    = "sg-cache"
  data_subnet_ids            = ["subnet-data-a", "subnet-data-c"]
  database_security_group_id = "sg-database"
  environment                = "dev"
  postgres_engine_version    = "17.8"
  project_name               = "kdt-travelplanner"
}

run "data_services_are_private_and_encrypted" {
  command = plan

  assert {
    condition = (
      !aws_db_instance.this.publicly_accessible &&
      !aws_db_instance.this.multi_az &&
      aws_db_instance.this.storage_encrypted &&
      aws_db_instance.this.manage_master_user_password &&
      !aws_db_instance.this.auto_minor_version_upgrade
    )
    error_message = "RDS must be private, encrypted, Single-AZ, patch-pinned and use an RDS-managed password."
  }

  assert {
    condition = (
      aws_elasticache_replication_group.this.num_cache_clusters == 1 &&
      aws_elasticache_replication_group.this.at_rest_encryption_enabled &&
      aws_elasticache_replication_group.this.transit_encryption_enabled &&
      aws_elasticache_replication_group.this.transit_encryption_mode == "required" &&
      length(aws_elasticache_replication_group.this.user_group_ids) == 1
    )
    error_message = "Redis must be a single encrypted node authenticated via the RBAC user group (D-001-R1 후속: auth_token replaced by user_group_ids)."
  }

  assert {
    condition     = aws_db_instance.this.skip_final_snapshot && !aws_db_instance.this.deletion_protection
    error_message = "The reproducible dev runtime must be destroyable without a final snapshot."
  }

  assert {
    condition = (
      aws_elasticache_user.default.user_name == "default" &&
      aws_elasticache_user.default.authentication_mode[0].type == "password"
    )
    error_message = "The default Redis user must keep password authentication so the backend app's existing access is unaffected."
  }

  assert {
    condition = (
      aws_elasticache_user.load_test.authentication_mode[0].type == "iam" &&
      aws_elasticache_user.load_test.user_id == aws_elasticache_user.load_test.user_name &&
      length(aws_elasticache_user.load_test.user_id) <= 40 &&
      aws_elasticache_user.load_test.access_string == "on ~* -@all +set +del"
    )
    error_message = "The load-test Redis RBAC user must use the same <=40-character IAM user_id/user_name (never a Secret) and be scoped to only SET/DEL (D-001-R1 후속 Seed/Cleanup 최소권한)."
  }

  assert {
    condition     = length(aws_elasticache_user.default.user_id) <= 40
    error_message = "The default Redis user ID must remain within ElastiCache's 40-character identity limit."
  }

  assert {
    condition = length(setsubtract(
      [aws_elasticache_user.default.user_id, aws_elasticache_user.load_test.user_id],
      aws_elasticache_user_group.this.user_ids,
    )) == 0
    error_message = "The user group must contain both the default and load-test Redis users."
  }
}
