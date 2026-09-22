variable "project_name" {
  type    = string
  default = "aquasentinel"
}

variable "cost_allocation_tag_keys" {
  description = "Cost Explorer/Budgets가 그룹핑 기준으로 쓸 태그 키 (계획서 16절 'project/owner 태그 강제')."
  type        = list(string)
  default     = ["project", "environment", "owner"]
}

variable "budget_name" {
  type    = string
  default = null # null이면 "{project_name}-monthly"로 자동 생성
}

variable "budget_limit_usd" {
  description = "월간 예산 상한(USD). 계획서 16절 전체 8주 추정 비용(~$270~290)을 참고해 조정할 것."
  type        = string
  default     = "150"
}

variable "budget_notification_emails" {
  description = "50/80/100% 임계값 알림을 받을 이메일 목록. 최소 1개 필요."
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
