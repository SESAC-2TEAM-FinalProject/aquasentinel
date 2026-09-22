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
  description = "서울과 동일한 도메인. 같은 wonju.cloud zone에 도쿄 리전 전용 인증서를 별도로 발급받는다."
  type        = string
  default     = "wonju.cloud"
}
