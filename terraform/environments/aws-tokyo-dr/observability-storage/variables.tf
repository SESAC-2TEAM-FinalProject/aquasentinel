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
  type = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "seoul_environment" {
  description = "크로스리전 읽기 대상(서울) 환경 이름 — seoul observability-storage state 경로 조립에 쓴다."
  type        = string
  default     = "dev"
}

variable "seoul_region" {
  type    = string
  default = "ap-northeast-2"
}
