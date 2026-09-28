variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "repository_names" {
  description = <<-EOT
    API 모듈 제작계획서(2026-09-28 최종안) 2.0.2절 이미지 이름 기준 — 어댑터별
    분리 구조(adapter-*)와 interpolation-svc/prediction-svc/evaluation-svc
    3분리는 이 계획서에서 5개 이미지(collector/processor/interpolation/
    grading/evaluation)로 통합됐다. alert-svc/status-svc/aggregation-svc는
    웹 서비스 소유(0.2절 범위 밖)라 이 목록에 넣지 않음 — 그 쪽 이미지 이름이
    확정되면 별도로 추가.
  EOT
  type        = list(string)
  default = [
    "api-module/collector",
    "api-module/processor",
    "api-module/interpolation",
    "api-module/grading",
    "api-module/evaluation",
  ]
}

variable "image_tag_mutability" {
  description = "IMMUTABLE — 같은 태그로 덮어쓰기를 막아 배포 추적성을 보장한다."
  type        = string
  default     = "IMMUTABLE"
}

variable "scan_on_push" {
  type    = bool
  default = true
}

variable "untagged_image_expiry_days" {
  description = "태그 없는 이미지(빌드 중간 산출물 등)를 이 기간 후 자동 정리해 ECR 저장 비용 누적을 막는다."
  type        = number
  default     = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}
