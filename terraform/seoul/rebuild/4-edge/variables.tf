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
  description = "bootstrap output.tfstate_bucket_name 값. 2-cluster/persistent state를 읽기 위해 필요."
  type        = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "require_alb" {
  description = "true면 Gateway ALB를 못 찾을 때 apply를 실패시킨다. aws-dns 모듈은 ALB가 없으면 헬스체크·레코드를 에러 없이 건너뛰는데, 그러면 트랙 B 감시도 조용히 사라진다. destroy 등 ALB가 없는 게 정상인 작업에서만 false로 준다."
  type        = bool
  default     = true
}
