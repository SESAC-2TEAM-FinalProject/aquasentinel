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
    grading/evaluation)로 통합됐다.

    웹 서비스(aquasentinel-web 레포) 이미지 3종(web-frontend/status-svc/
    ocean-batch)은 2026-10-01 이미지 이름 확정(HANDOFF.md 1절)에 따라 추가함.
    alert-svc는 아직 미구현이라 레포만 안 만듦 — 이미지가 생기면 추가.
  EOT
  type        = list(string)
  default = [
    "api-module/collector",
    "api-module/processor",
    "api-module/interpolation",
    "api-module/grading",
    "api-module/evaluation",
    "web-frontend",
    "status-svc",
    "ocean-batch",
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

variable "enable_cross_region_replication" {
  description = <<-EOT
    ECR 크로스리전 복제(aws_ecr_replication_configuration)는 AWS 계정 전체에
    하나만 존재 가능한 싱글톤 리소스다 — 서울·도쿄 두 환경이 같은 모듈을
    호출하더라도, 반드시 한쪽(서울, 소스 리전)에서만 true로 켜야 한다. 양쪽 다
    켜면 Terraform이 같은 계정 설정을 두 state에서 동시에 관리하려다 충돌한다.
    DR 회의(2026-09-30) 안건 5에서 A안으로 확정 — 도쿄는 이 값을 false로 둔다.
  EOT
  type        = bool
  default     = false
}

variable "replication_destination_region" {
  description = "복제 대상 리전. enable_cross_region_replication이 true일 때만 사용된다."
  type        = string
  default     = ""
}
