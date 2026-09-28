variable "project_name" {
  type    = string
  default = "aquasentinel"
}

variable "owner" {
  type    = string
  default = "team-aquasentinel"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "tfstate_bucket" {
  type = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "redis_node_type" {
  type    = string
  default = "cache.t3.micro"
}

variable "redis_automatic_failover_enabled" {
  description = "서울(운영) 환경은 기본으로 켠다 — Primary+Replica + Multi-AZ 자동 페일오버(팀 결정 2026-09-23, 이중화 옵션 A)."
  type        = bool
  default     = true
}
