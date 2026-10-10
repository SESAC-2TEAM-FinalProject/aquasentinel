variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "buckets" {
  description = <<-EOT
    만들 버킷 목록(key = 식별자, output에서 그대로 참조됨).
    - name_suffix: 버킷 이름 접미사 (name_prefix-{suffix}-{account_id})
    - enable_versioning: 복제를 쓰려면 true여야 함(AWS 요구사항)
    - noncurrent_version_expiration_days: enable_versioning=true일 때만 의미 있음
    - expiration_rules: 현재 버전 만료 규칙 목록(prefix=""면 버킷 전체)
    - enable_cross_region_replication / replication_destination_bucket_arn:
      서울(소스)에서만 true로 켠다
  EOT
  type = map(object({
    name_suffix                        = string
    enable_versioning                  = optional(bool, false)
    noncurrent_version_expiration_days = optional(number, 14)
    expiration_rules = optional(list(object({
      id     = string
      prefix = optional(string, "")
      days   = number
    })), [])
    enable_cross_region_replication    = optional(bool, false)
    replication_destination_bucket_arn = optional(string, "")
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}
