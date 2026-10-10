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

variable "tags" {
  type    = map(string)
  default = {}
}
