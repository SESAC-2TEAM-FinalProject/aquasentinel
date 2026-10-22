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
  description = "이미 Route53에 존재하는 Hosted Zone 이름. 저장소가 public이라 기본값으로 두지 않는다 — terraform.tfvars에 채운다."
  type        = string
}

variable "loki_retention_days" {
  description = "도쿄 Loki 버킷의 현재 버전 만료 일수. 서울(seoul/persistent/variables.tf)과 같은 값으로 둔다 — 리전마다 다르면 DR 전환 뒤 로그 보관 기간이 조용히 바뀐다."
  type        = number
  default     = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}
