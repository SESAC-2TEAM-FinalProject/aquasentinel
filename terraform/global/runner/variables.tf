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
  description = "bootstrap output.tfstate_bucket_name 값. network state를 읽기 위해 필요(서브넷에 EC2를 배치)."
  type        = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "instance_type" {
  description = "러너 EC2 인스턴스 타입. 온디맨드로 운영(2026-10-14 팀 결정 — 스팟 미사용)."
  type        = string
  default     = "t3.medium"
}

variable "runner_concurrent" {
  description = "config.toml concurrent 값. 클러스터 내부 러너는 10이었지만 그건 클러스터 전체 용량 기준값이라, t3.medium 단일 호스트 사양에 맞춰 보수적으로 시작한다."
  type        = number
  default     = 3
}


