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
  description = "bootstrap output.tfstate_bucket_name 값. 2-cluster/persistent state를 읽기 위해 필요."
  type        = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "require_alb" {
  description = "true면 Gateway ALB를 못 찾을 때 apply를 실패시킨다. aws-dns 모듈은 ALB가 없으면 헬스체크·레코드를 에러 없이 건너뛰는데, 그러면 트랙 B 감시도 조용히 사라진다. destroy 등 ALB가 없는 게 정상인 작업에서만 false로 준다."
  type        = bool
  default     = true
}

variable "drill_health_check_inverted" {
  description = <<-EOT
    🔴 DR 훈련 스위치(2026-10-27). true 면 dr-drill.<도메인> 의 PRIMARY 판정을
    뒤집어 도쿄(SECONDARY)로 넘긴다. 운영 레코드 3개(apex · auth · grafana)는
    **영향을 받지 않는다** — 헬스체크가 따로다(modules/aws-dns 주석).

    쓰는 법: `terraform apply -var drill_health_check_inverted=true`
    되돌리기: 같은 명령에 false. 전환까지 약 90초 + ALIAS 캐시 최대 60초.

    🔴 기본값 false 를 코드에 박아 둔 채로 머지한다 — true 로 머지하면
    머지 즉시 전환이 걸린다.
  EOT
  type        = bool
  default     = false
}
