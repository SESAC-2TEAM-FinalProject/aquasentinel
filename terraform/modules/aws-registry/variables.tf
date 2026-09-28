variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "repository_names" {
  description = "계획서 11.1절 파드 인벤토리(어댑터 4종 + interpolation/prediction/evaluation/alert/status/aggregation) 기준 기본 서비스 목록."
  type        = list(string)
  default = [
    "adapter-bulletin",
    "adapter-tide-wt",
    "adapter-line",
    "adapter-fishery",
    "interpolation-svc",
    "prediction-svc",
    "evaluation-svc",
    "alert-svc",
    "status-svc",
    "aggregation-svc",
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
