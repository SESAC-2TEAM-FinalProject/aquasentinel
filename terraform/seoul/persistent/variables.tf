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
  description = "bootstrap output.tfstate_bucket_name 값. 도쿄 persistent state를 읽기 위해 필요(복제 대상 버킷 ARN)."
  type        = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "domain_name" {
  description = "이미 Route53에 존재하는 Hosted Zone 이름. 저장소가 public이라 기본값으로 두지 않는다 — terraform.tfvars에 채운다."
  type        = string
}

variable "noncurrent_version_expiration_days" {
  description = "버저닝(복제 전제조건)으로 생기는 과거 버전을 정리하는 기간."
  type        = number
  default     = 14
}

variable "thanos_retention_days" {
  type    = number
  default = 30
}

variable "loki_retention_days" {
  type    = number
  default = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "alarm_email_endpoints" {
  description = "트랙 B 알람(SNS) 이메일 수신자. CI 변수 TF_VAR_alarm_email_endpoints로 넣는다(예: [\"a@example.com\"]). 비우면 구독 없이 토픽만 만든다. 구독 후 각 수신자가 확인 메일을 눌러야 메일이 온다."
  type        = list(string)
  default     = []
}
