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
  description = "bootstrap output.tfstate_bucket_name 값(서울 리전 버킷을 그대로 참조). 2-cluster/persistent state를 읽기 위해 필요."
  type        = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}

# (2026-10-20 리전 대조) 서울에만 있던 가드. aws-dns 모듈은 ALB 를 못 찾으면
# 헬스체크·레코드를 **에러 없이 건너뛴다** — 가드가 없으면 4-edge apply 가
# 성공하는데 페일오버 레코드가 안 생기고, 아무도 그걸 모른다. 도쿄는 지운
# 상태에서 4단계를 연달아 돌리는 경로라 이 자리를 실제로 탄다.
variable "require_alb" {
  description = "true면 Gateway ALB를 못 찾을 때 apply를 실패시킨다. destroy 등 ALB가 없는 게 정상인 작업에서만 false로 준다."
  type        = bool
  default     = true
}
