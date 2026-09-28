variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_data_subnet_ids" {
  description = "ElastiCache가 위치할 private-data 서브넷 (계획서 11.7절)."
  type        = list(string)
}

variable "allowed_security_group_id" {
  description = "EKS 노드(클러스터 보안그룹)만 6379에 접근하도록 허용한다 — 계획서 11.7절 'node-sg만' 규칙."
  type        = string
}

# --- ElastiCache ---

variable "redis_node_type" {
  type    = string
  default = "cache.t3.micro"
}

variable "redis_engine_version" {
  type    = string
  default = "7.1"
}

variable "redis_automatic_failover_enabled" {
  description = "모듈 기본값은 false(도쿄 드릴처럼 비용에 민감한 환경 대비 보수적 기본값). true면 Primary+Replica 구성 + Multi-AZ 자동 페일오버(ElastiCache Replication Group, ~60초 내 자동 승격). 서울(운영) 환경은 environments/aws-seoul-dev/data에서 true로 재정의 — 팀 결정(2026-09-23, 이중화 옵션 A)."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
