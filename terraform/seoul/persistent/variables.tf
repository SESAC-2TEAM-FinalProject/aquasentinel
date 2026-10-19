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

variable "testfield_account_ids" {
  description = <<-EOT
    시험 구역(테스트 필드) 계정 ID 목록. 운영 백업 버킷의 cloudnativepg/ 접두사를
    읽기 전용으로 열어 준다 — 시험 구역이 운영 기준 백업에서 DB를 복구할 수 있게
    하기 위한 것이고(D-17, SIM-09a), 그 외 용도는 없다.

    비우면 버킷 정책을 아예 만들지 않는다 — 시험 구역을 닫으면 목록에서 빼고
    apply 하면 권한이 사라진다.

    CI 는 tfvars 를 읽지 않으므로(.gitlab-ci.yml 은 -var-file 을 주지 않는다)
    값을 여기 default 에 둔다. tfvars 로만 넣으면 다음 CI apply 가 정책을
    지워 버린다. ECR 의 pull_only_account_ids 를 main.tf 에 직접 적어 둔 것과
    같은 이유다.

    실제로 쓰이는 값은 main.tf 의 local.testfield_account_ids 다 — 운영 계정에서
    apply 할 때만 이 목록이 적용되고, 시험 계정이 같은 코드를 돌리면 빈 목록이
    된다(그 쪽 주석 참고).

    ECR pull 허용은 별도다(module "registry" 의 pull_only_account_ids).
  EOT
  type        = list(string)
  default = [
    "926762923779", # 재희님 — 시험 구역 1 (ECR pull 도 이 계정으로 열려 있다)
    "383344224073", # 창영님 — 시험 구역 2
  ]
}
