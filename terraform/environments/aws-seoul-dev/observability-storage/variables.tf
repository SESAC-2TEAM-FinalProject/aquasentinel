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
  type = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "tokyo_environment" {
  description = "복제 대상(도쿄) 환경 이름 — tokyo observability-storage state 경로 조립에 쓴다."
  type        = string
  default     = "dr-tokyo"
}

variable "tokyo_region" {
  type    = string
  default = "ap-northeast-1"
}
