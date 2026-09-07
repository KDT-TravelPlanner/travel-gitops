output "database_address" {
  description = "RDS PostgreSQL hostname."
  value       = aws_db_instance.this.address
}

output "database_master_secret_arn" {
  description = "RDS-managed master credential secret ARN."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "database_name" {
  description = "Initial PostgreSQL database name."
  value       = aws_db_instance.this.db_name
}

output "database_identifier" {
  description = "RDS DB instance identifier used by CloudWatch dimensions."
  value       = aws_db_instance.this.identifier
}

output "database_port" {
  description = "RDS PostgreSQL port."
  value       = aws_db_instance.this.port
}

output "redis_auth_secret_arn" {
  description = "Secrets Manager ARN containing the generated Redis password."
  value       = aws_secretsmanager_secret.redis.arn
}

output "redis_primary_endpoint" {
  description = "Redis primary endpoint hostname."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "redis_port" {
  description = "Redis TLS port."
  value       = aws_elasticache_replication_group.this.port
}

output "redis_replication_group_id" {
  description = "ElastiCache replication group ID used by IAM signing and CloudWatch dimension resolution."
  value       = aws_elasticache_replication_group.this.id
}

output "redis_member_cluster_ids" {
  description = "ElastiCache member cluster IDs available for node-level CloudWatch dimensions."
  value       = aws_elasticache_replication_group.this.member_clusters
}

output "redis_load_test_user_name" {
  description = "ElastiCache RBAC username the load-test Runner authenticates as via IAM (D-001-R1 후속 Seed/Cleanup 최소권한). Not secret — pass to orchestrate-aws-b01.sh --redis-iam-user."
  value       = aws_elasticache_user.load_test.user_name
}

output "redis_load_test_user_arn" {
  description = "ARN of the load-test RBAC user, for the Runner's elasticache:Connect IAM policy."
  value       = aws_elasticache_user.load_test.arn
}

output "redis_replication_group_arn" {
  description = "ARN of the Redis replication group, for the Runner's elasticache:Connect IAM policy (both the user and the replication group ARN are required)."
  value       = aws_elasticache_replication_group.this.arn
}
