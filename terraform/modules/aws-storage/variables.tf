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
    - cross_account_read: 다른 계정이 접두사 아래를 읽기만 하게 한다(버킷 정책).
      prefixes는 반드시 좁힌다 — 버킷 하나에 여러 용도가 섞여 있다.
      단 prefixes가 좁히는 것은 **객체 읽기(GetObject)**뿐이다. 버킷 수준
      액션(ListBucket·GetBucketLocation)에는 조건을 걸지 않는다 — barman-cloud의
      HeadBucket 호출에 s3:prefix가 실리지 않아 조건을 걸면 거부된다(main.tf 머리말).
      또한 이건 리소스 쪽 허용일 뿐이다. 계정이 다르면 **읽는 쪽 IAM 역할에도**
      같은 버킷 허용이 있어야 실제로 읽힌다(2-cluster/irsa.tf).
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

    cross_account_read = optional(object({
      account_ids = list(string)
      prefixes    = list(string) # 예: ["cloudnativepg/*"] — "*" 는 쓰지 않는다
    }), null)
  }))

  validation {
    condition = alltrue([
      for b in values(var.buckets) :
      b.cross_account_read == null ? true : (
        length(b.cross_account_read.account_ids) > 0 &&
        length(b.cross_account_read.prefixes) > 0 &&
        !contains(b.cross_account_read.prefixes, "*")
      )
    ])
    error_message = "cross_account_read: account_ids·prefixes 는 비울 수 없고, prefixes 에 \"*\"(버킷 전체)는 허용하지 않는다. 접두사를 좁힐 것."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
