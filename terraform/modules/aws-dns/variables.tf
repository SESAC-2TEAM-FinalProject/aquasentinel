variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "domain_name" {
  description = "이미 Route53에 존재하는 Hosted Zone 이름 (apex 그대로 사용). 나중에 프로젝트 전용 도메인을 구매하면 이 값만 바꾸면 된다."
  type        = string
}

variable "include_wildcard_san" {
  description = "true면 *.domain_name도 SAN에 포함해 Grafana·Argo CD 등 서브도메인 노출을 대비한다."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
