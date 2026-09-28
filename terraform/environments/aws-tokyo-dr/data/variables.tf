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
  default = "dr-tokyo"
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
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
  description = "도쿄 드릴 환경은 비용에 민감해 기본 false(단일 노드) 유지."
  type        = bool
  default     = false
}
