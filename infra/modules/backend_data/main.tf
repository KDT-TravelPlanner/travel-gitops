locals {
  name = "${var.project_name}-${var.environment}"

  # ElastiCache user IDs and names are limited to 40 characters. Keep the
  # identity stable and unique for this project/environment while ensuring
  # the IAM-authenticated user_id and user_name are exactly the same value.
  redis_name_hash               = substr(sha1(local.name), 0, 8)
  redis_default_user_id         = "${substr(local.name, 0, 24)}-${local.redis_name_hash}-def"
  redis_load_test_user_identity = "${substr(local.name, 0, 20)}-${local.redis_name_hash}-loadtest"
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-database"
  subnet_ids = var.data_subnet_ids
  tags       = var.tags
}

resource "aws_db_instance" "this" {
  identifier = "${local.name}-postgres"

  allocated_storage           = 20
  max_allocated_storage       = 100
  storage_type                = "gp3"
  storage_encrypted           = true
  engine                      = "postgres"
  engine_version              = var.postgres_engine_version
  instance_class              = var.db_instance_class
  db_name                     = var.database_name
  username                    = var.database_username
  manage_master_user_password = true
  port                        = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.database_security_group_id]
  publicly_accessible    = false
  multi_az               = false

  auto_minor_version_upgrade   = false
  apply_immediately            = true
  backup_retention_period      = 1
  copy_tags_to_snapshot        = true
  deletion_protection          = false
  performance_insights_enabled = false
  skip_final_snapshot          = true

  tags = var.tags
}

resource "random_password" "redis_auth" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "redis" {
  name                    = "${local.name}/redis/auth"
  description             = "Generated Redis authentication token for the ephemeral ${var.environment} runtime"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "redis" {
  secret_id = aws_secretsmanager_secret.redis.id
  secret_string = jsonencode({
    password = random_password.redis_auth.result
  })
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name}-cache"
  subnet_ids = var.data_subnet_ids
  tags       = var.tags
}

# ── Redis RBAC users ────────────────────────────────────────────
# D-001-R1 후속 "Seed/Cleanup 최소권한" (aws-load-test-handoff/decisions/
# DECISION_LOG.md): the load-test Runner must never authenticate as the
# shared default user / AUTH token the backend app uses. It gets its own
# RBAC user authenticated via IAM instead of a password, so no Redis
# credential for it ever exists in a Secret, in Terraform state, or in plan
# output (the "default" user below keeps the *existing* password-based
# behavior unchanged — same random_password as before — so the backend app
# is unaffected).
#
# IMPORTANT MIGRATION NOTE for whoever applies this: attaching
# user_group_ids to an existing replication_group that previously set
# auth_token directly is a real behavior change to how ElastiCache manages
# the default user's auth (now via aws_elasticache_user.default instead of
# the replication_group resource itself), even though the password value is
# unchanged. Review `terraform plan` carefully before applying — this may
# show as an in-place update or, depending on provider version, a
# forced replacement of the replication group. Apply in a maintenance
# window; this was not tested against live AWS in this change (see PR body
# "중요한 한계").
resource "aws_elasticache_user" "default" {
  user_id       = local.redis_default_user_id
  user_name     = "default"
  engine        = "redis"
  access_string = "on ~* +@all"

  authentication_mode {
    type      = "password"
    passwords = [random_password.redis_auth.result]
  }

  tags = var.tags
}

# Least-privilege by command, not by key pattern: seed/cleanup only ever
# SET (with PX ttl) and DEL exact auth:refresh:token:*/auth:refresh:family:*
# keys (scripts/loadtest/aws/{seed,cleanup}-aws-load-data.py). Those keys
# share the same namespace real user sessions use — the backend doesn't
# prefix load-test keys separately — so key-pattern (~) scoping can't
# isolate load-test access from real traffic without an application change,
# which is out of scope here. Command scoping (-@all +set +del) is the
# actual isolation boundary: this user cannot GET, SCAN, FLUSHALL, or run
# any other command even though it can technically address any key.
resource "aws_elasticache_user" "load_test" {
  user_id       = local.redis_load_test_user_identity
  user_name     = local.redis_load_test_user_identity
  engine        = "redis"
  access_string = "on ~* -@all +set +del"

  authentication_mode {
    type = "iam"
  }

  tags = var.tags
}

resource "aws_elasticache_user_group" "this" {
  engine        = "redis"
  user_group_id = "${local.name}-redis-users"
  user_ids = [
    aws_elasticache_user.default.user_id,
    aws_elasticache_user.load_test.user_id,
  ]

  tags = var.tags
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${local.name}-redis"
  description          = "${var.environment} TravelPlanner Redis OSS cache"

  engine             = "redis"
  engine_version     = var.redis_engine_version
  node_type          = var.cache_node_type
  num_cache_clusters = 1
  port               = 6379

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  # auth_token/auth_token_update_strategy intentionally removed: the default
  # user's password is now owned by aws_elasticache_user.default above, and
  # this replication group is instead assigned the RBAC user group (both
  # the unchanged default user and the new IAM-authenticated load-test
  # user). Do not add auth_token back — AWS rejects setting both auth_token
  # and user_group_ids on the same replication group.
  user_group_ids = [aws_elasticache_user_group.this.id]

  automatic_failover_enabled = false
  multi_az_enabled           = false
  apply_immediately          = true
  snapshot_retention_limit   = 0

  security_group_ids = [var.cache_security_group_id]
  subnet_group_name  = aws_elasticache_subnet_group.this.name

  tags = var.tags
}
