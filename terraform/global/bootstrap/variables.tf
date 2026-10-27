variable "project_name" {
  description = "프로젝트 식별자. 모든 리소스 네이밍의 접두사로 쓰인다."
  type        = string
  default     = "aquasentinel"
}

variable "bootstrap_region" {
  description = "Terraform state 버킷을 생성할 리전. 이 버킷 하나가 모든 environment(dev/dr-tokyo)의 state를 key 경로로 구분해 저장한다."
  type        = string
  default     = "ap-northeast-2"
}

variable "enable_tfstate_replication" {
  description = <<-EOT
    tfstate 버킷을 도쿄로 복제할지(CRR). 🔴 끄면 **진짜 서울 장애에서 도쿄를
    세울 수 없다** — 13개 컴포넌트의 backend.hcl 이 전부 서울 버킷을 가리키기
    때문이다(2026-10-26 실측). DR 시나리오 문서의 `[가정 예외]` 가 그것이다.

    이 컴포넌트는 CI 범위 밖이라(최초 1회 수동 적용 · `.gitlab-ci.yml` 머리말)
    true 로 둬도 저절로 만들어지지 않는다. 사람이 apply 할 때 만들어진다.

    🔴 켠 뒤 **1회 전량 동기화**가 필요하다 — 복제는 설정 뒤에 쓰인 객체만
    옮기므로, 한동안 apply 하지 않은 컴포넌트는 복제본이 비어 있다.
    절차: `runbooks/Terraform상태_리전전환.md`
  EOT
  type        = bool
  default     = true
}

variable "tfstate_replica_region" {
  description = "tfstate 복제본을 둘 리전. DR 대상 리전과 같아야 의미가 있다."
  type        = string
  default     = "ap-northeast-1"

  validation {
    condition     = var.tfstate_replica_region != var.bootstrap_region
    error_message = "복제본 리전은 원본 리전과 달라야 한다 — 같으면 리전 장애에 대비가 안 된다."
  }
}
