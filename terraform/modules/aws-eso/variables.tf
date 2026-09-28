variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "oidc_provider_arn" {
  description = "aws-eks 모듈 output.oidc_provider_arn."
  type        = string
}

variable "oidc_provider_url" {
  description = "aws-eks 모듈 output.oidc_provider_url (https:// 접두사 포함)."
  type        = string
}

variable "namespace" {
  description = "ESO가 배포될 네임스페이스. IRSA 신뢰조건의 sub 값에 들어간다."
  type        = string
  default     = "external-secrets"
}

variable "service_account_name" {
  type    = string
  default = "external-secrets"
}

variable "tags" {
  type    = map(string)
  default = {}
}
