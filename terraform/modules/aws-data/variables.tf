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
  description = "RDS·ElastiCache가 위치할 private-data 서브넷 (계획서 11.7절)."
  type        = list(string)
}

variable "allowed_security_group_id" {
  description = "EKS 노드(클러스터 보안그룹)만 3306/6379에 접근하도록 허용한다 — 계획서 11.7절 'node-sg만' 규칙."
  type        = string
}

# --- RDS ---

variable "rds_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "rds_engine_version" {
  description = "마이너 버전은 고정하지 않는다 (auto_minor_version_upgrade로 자동 패치)."
  type        = string
  default     = "8.0"
}

variable "rds_allocated_storage" {
  type    = number
  default = 20
}

variable "rds_database_name" {
  type    = string
  default = "aquasentinel"
}

variable "rds_username" {
  type    = string
  default = "aquasentinel_admin"
}

variable "rds_multi_az" {
  description = "false 기본 — 이 프로젝트의 카오스 실험(14.3절)은 DB 가용성이 아니라 앱 계층(adapter/prediction-svc)을 검증 대상으로 하고, Multi-AZ는 비용이 약 2배라 16절 예산 제약과 충돌한다."
  type        = bool
  default     = false
}

variable "rds_backup_retention_days" {
  type    = number
  default = 7
}

variable "rds_deletion_protection" {
  type    = bool
  default = false
}

variable "rds_skip_final_snapshot" {
  description = "false로 두면 destroy 시 최종 스냅샷을 남긴다 (계획서 18.5절 종료 후 보존 대응)."
  type        = bool
  default     = false
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

variable "tags" {
  type    = map(string)
  default = {}
}
