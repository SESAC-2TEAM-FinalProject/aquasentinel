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

variable "source_environment" {
  description = "ECR 복제 원본(서울)의 environment 값 — 복제된 레포 이름이 이 값을 그대로 쓴다."
  type        = string
  default     = "dev"
}

variable "source_region" {
  description = "ECR 복제 원본(서울) 리전 — repository_urls에서 이 리전 문자열을 도쿄 리전으로 치환한다."
  type        = string
  default     = "ap-northeast-2"
}
