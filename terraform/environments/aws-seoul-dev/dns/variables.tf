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
  description = "이미 Route53에 존재하는 Hosted Zone 이름 (apex 그대로 사용). 실제 값은 terraform.tfvars에 채운다 — 저장소가 public이라 기본값으로 두지 않는다."
  type        = string
}

variable "tfstate_bucket" {
  description = "eks environment의 state를 읽어 Gateway API ALB 조회용 cluster_name을 가져오기 위함."
  type        = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}
