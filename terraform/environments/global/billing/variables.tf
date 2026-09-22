variable "project_name" {
  type    = string
  default = "aquasentinel"
}

variable "owner" {
  type    = string
  default = "team-aquasentinel"
}

variable "budget_limit_usd" {
  type    = string
  default = "150"
}

variable "budget_notification_emails" {
  description = "팀원 이메일 최소 1개 이상. 실제 값은 terraform.tfvars에 채운다."
  type        = list(string)
}
