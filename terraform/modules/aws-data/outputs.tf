output "rds_endpoint" {
  value = aws_db_instance.this.address
}

output "rds_port" {
  value = aws_db_instance.this.port
}

output "rds_database_name" {
  value = aws_db_instance.this.db_name
}

output "rds_secret_arn" {
  description = "ESO가 나중에 이 시크릿을 동기화해간다 (username/password JSON)."
  value       = aws_secretsmanager_secret.rds.arn
}

output "redis_endpoint" {
  value = aws_elasticache_cluster.this.cache_nodes[0].address
}

output "redis_port" {
  value = aws_elasticache_cluster.this.port
}
