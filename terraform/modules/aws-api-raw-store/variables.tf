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
# API 모듈의 handoff/HANDOFF.md가 아직 인계되지 않아 실제 네임스페이스·
# 서비스어카운트 이름이 확정되지 않았다. 여기 기본값은 API 모듈 제작계획서가
# 저장소 이름으로 쓰는 "api-module"과 이미지 이름(collector/processor)을
# 그대로 따른 잠정값 — 인계 후 실제 값과 다르면 이 변수만 바꾸면 된다
# (트러스트 정책의 sub 조건만 바뀌므로 재생성 없이 in-place 업데이트된다).
# ---------------------------------------------------------------------------

variable "namespace" {
  description = "API 모듈이 배포될 네임스페이스. IRSA 신뢰조건의 sub 값에 들어간다."
  type        = string
  default     = "api-module"
}

variable "collector_service_account_name" {
  description = "collector 이미지(원문 저장 — PutObject) 서비스어카운트."
  type        = string
  default     = "collector"
}

variable "processor_service_account_name" {
  description = "processor 이미지(원문 읽기 — GetObject, reprocess Job 포함) 서비스어카운트."
  type        = string
  default     = "processor"
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
  description = "복제 대상(도쿄) raw-store 버킷 ARN. enable_cross_region_replication이 true일 때만 사용된다."
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
