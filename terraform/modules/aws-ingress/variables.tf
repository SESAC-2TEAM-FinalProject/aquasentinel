variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "cluster_name" {
  description = "IAM 정책의 aws:ResourceTag/elbv2.k8s.aws/cluster 조건과는 무관하지만, 리소스 네이밍과 로그 추적용으로 사용."
  type        = string
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
  description = "컨트롤러가 배포될 네임스페이스. IRSA 신뢰조건의 sub 값에 들어간다."
  type        = string
  default     = "kube-system"
}

variable "service_account_name" {
  type    = string
  default = "aws-load-balancer-controller"
}

variable "tags" {
  type    = map(string)
  default = {}
}
