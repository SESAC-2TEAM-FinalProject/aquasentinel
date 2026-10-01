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

variable "domain_name" {
  description = "서울과 동일한 도메인(같은 Hosted Zone에 도쿄 리전 전용 인증서를 별도 발급). 실제 값은 terraform.tfvars에 채운다 — 저장소가 public이라 기본값으로 두지 않는다."
  type        = string
}

variable "tfstate_bucket" {
  description = "eks environment의 state를 읽어 Gateway API ALB 조회용 cluster_name을 가져오기 위함. tfstate 버킷은 항상 서울 리전에 있다."
  type        = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}
