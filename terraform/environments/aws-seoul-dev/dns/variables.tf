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

variable "domain_name" {
  description = "지금은 개인 도메인(wonju.cloud)을 apex 그대로 사용. 나중에 프로젝트 전용 도메인을 사면 이 값만 바꾼다."
  type        = string
  default     = "wonju.cloud"
}
