variable "role_name" {
  description = "IAM Role 이름."
  type        = string
}

variable "oidc_provider_arn" {
  description = "aws-eks 모듈 output.oidc_provider_arn. 이 클러스터 안 파드만 이 Role을 assume할 수 있다."
  type        = string
}

variable "namespace_service_accounts" {
  description = "이 Role을 assume할 수 있는 \"namespace:service_account\" 목록. 보통 1개지만, 같은 권한을 여러 SA가 공유해야 하면 여러 개를 넣는다."
  type        = list(string)
}

variable "policy_arns" {
  description = "이 Role에 attach할 IAM Policy ARN 맵(key는 임의 식별자). 정책 내용 자체는 호출하는 쪽이 만든다."
  type        = map(string)
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
