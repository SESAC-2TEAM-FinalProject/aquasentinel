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
  description = "bootstrap output.tfstate_bucket_name 값(서울 리전 버킷을 그대로 참조). 1-network/2-cluster/persistent state를 읽기 위해 필요."
  type        = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "gitops_revision" {
  description = "Argo CD 가 읽을 gitops 브랜치 — root(하위 앱 12개)와 Terraform 앱 9개가 같이 따른다. 시험 구역 · 브랜치 미리보기 때만 바꾼다."
  type        = string
  default     = "main"
}
