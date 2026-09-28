output "redis_endpoint" {
  description = "Primary Endpoint — 페일오버 시 AWS가 자동으로 새 Primary를 가리키도록 갱신하는 고정 DNS. 단일 노드 모드에서도 동일 속성으로 접근 가능."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "redis_port" {
  value = aws_elasticache_replication_group.this.port
}
