locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ---------------------------------------------------------------------------
# 관계형 DB는 RDS를 쓰지 않는다 — CloudNativePG(자체운영, K8s/GitOps 계층)로
# 전환 확정(팀 결정 2026-09-23). 이 모듈은 더 이상 관계형 DB를 프로비저닝하지
# 않고, ElastiCache(Redis)만 관리한다. CloudNativePG 관련 리소스는 Terraform이
# 아니라 Argo CD가 관리하는 쿠버네티스 매니페스트 쪽에 위치한다.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# ElastiCache Redis — 4.7절 구독 조회 캐시, 3.2절 상태조회 캐시 용도.
# 이중화 옵션 A(Replication Group + Multi-AZ 자동 페일오버) 채택 — 팀 결정(2026-09-23).
# redis_automatic_failover_enabled=false인 환경(예: 도쿄 드릴)에서는 단일 노드로 동작.
# ---------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name_prefix}-redis"
  subnet_ids = var.private_data_subnet_ids

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-redis-subnet-group"
  })
}

resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-redis-sg"
  description = "Allow Redis(6379) from EKS nodes only" # AWS SG description은 ASCII만 허용
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from EKS nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.allowed_security_group_id]
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-redis-sg"
  })
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${local.name_prefix}-redis"
  description          = "AquaSentinel Redis cache" # ElastiCache description도 ASCII만 허용
  engine               = "redis"
  engine_version       = var.redis_engine_version
  node_type            = var.redis_node_type
  port                 = 6379

  # false면 1개(단일 노드), true면 2개(Primary+Replica) — automatic_failover는 replica가 최소 1개 필요
  num_cache_clusters         = var.redis_automatic_failover_enabled ? 2 : 1
  automatic_failover_enabled = var.redis_automatic_failover_enabled
  multi_az_enabled           = var.redis_automatic_failover_enabled

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-redis"
  })
}
