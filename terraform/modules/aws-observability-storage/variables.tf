variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "oidc_provider_arn" {
  description = "aws-eks 모듈 output.oidc_provider_arn."
  type        = string
}

variable "oidc_provider_url" {
  description = "aws-eks 모듈 output.oidc_provider_url (https:// 접두사 포함)."
  type        = string
}

# ---------------------------------------------------------------------------
# 워크로드별 IRSA 신뢰조건 — 네임스페이스/서비스어카운트는 실제 Helm 설치 시
# 값이 확정되므로 기본값은 각 프로젝트의 공식 chart 기본값을 따른다.
# ---------------------------------------------------------------------------

variable "thanos_namespace" {
  type    = string
  default = "monitoring"
}

variable "thanos_service_account_name" {
  type    = string
  default = "thanos"
}

variable "loki_namespace" {
  type    = string
  default = "monitoring"
}

variable "loki_service_account_name" {
  type    = string
  default = "loki"
}

variable "cloudnativepg_namespace" {
  type    = string
  default = "cnpg-system"
}

variable "cloudnativepg_service_account_name" {
  description = "Cluster가 배포될 네임스페이스의 barman-cloud 백업용 서비스어카운트. 실제 Cluster CR 작성 시 namespace가 cnpg-system이 아닐 수 있어 재확인 필요."
  type        = string
  default     = "cloudnativepg-backup"
}

# ---------------------------------------------------------------------------
# 라이프사이클 — Thanos/Loki는 자체 압축·다운샘플링 로직이 있어 S3 만료 규칙과
# 별개로 동작하지만, 팀의 실제 보관 정책이 정해지기 전까지는 비용 누적을 막기
# 위해 보수적으로 짧은 기본값을 둔다. CloudNativePG(Barman Cloud)는 자체
# retention-policy로 WAL/베이스 백업을 관리하므로 S3 라이프사이클을 걸지 않는다
# (걸면 PITR 윈도우를 Barman 모르게 깨뜨릴 수 있음).
# ---------------------------------------------------------------------------

variable "thanos_retention_days" {
  type    = number
  default = 30
}

variable "loki_retention_days" {
  type    = number
  default = 30
}

variable "noncurrent_version_expiration_days" {
  description = <<-EOT
    버저닝 활성화(크로스리전 복제 전제조건)로 생기는 과거 버전을 정리하는
    기간. DR 회의(2026-09-30) 안건 7에서 복제 방향(A안)은 확정했으나 정확한
    보관일수는 팀 논의 대기 중 — 비용 누적을 막기 위해 보수적인 기본값을 둔다.
  EOT
  type        = number
  default     = 14
}

variable "enable_cross_region_replication" {
  description = <<-EOT
    S3 Cross-Region Replication 활성화 여부. 서울(소스)에서만 true로 켠다 —
    도쿄는 복제 대상(destination)일 뿐 자기 복제 설정을 가지지 않는다.
  EOT
  type        = bool
  default     = false
}

variable "replication_destination_bucket_arn" {
  description = "복제 대상(도쿄) observability 버킷 ARN. enable_cross_region_replication이 true일 때만 사용된다."
  type        = string
  default     = ""
}

variable "enable_cross_region_read" {
  description = <<-EOT
    도쿄처럼 다른 리전의 observability 버킷(cloudnativepg/ prefix)을 읽어야
    하는 환경에서만 true로 켠다 — CNPG Replica Cluster(방식 B)가 서울의
    WAL/베이스 백업을 읽어 복구하려면 cloudnativepg IRSA 역할에 이 권한이
    필요하다(DR 회의 2026-09-30 안건 7 연장선).
  EOT
  type        = bool
  default     = false
}

variable "cross_region_read_bucket_arn" {
  description = "읽기 전용으로 접근할 원격 리전 observability 버킷 ARN. enable_cross_region_read가 true일 때만 사용된다."
  type        = string
  default     = ""
}

variable "cross_region_read_prefix" {
  description = "원격 버킷 안에서 읽기를 허용할 prefix(예: cloudnativepg/). enable_cross_region_read가 true일 때만 사용된다."
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
