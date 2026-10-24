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
  default = "dr-tokyo"
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "tfstate_bucket" {
  description = "bootstrap output.tfstate_bucket_name 값(서울 리전 버킷을 그대로 참조). 1-network/2-cluster/persistent state를 읽기 위해 필요."
  type        = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "suspend_collectors" {
  description = <<-EOT
    🔴 도쿄 collector CronJob 6개를 멈춘 채로 띄운다(훈련 모드).

    공공 API 키 4개(dtrecent·nifs bulletin/fishery-sea/line)는 도쿄 리전에도
    **서울과 같은 이름·같은 값**으로 들어가 있다 — applications.tf 의
    ExternalSecret 주석대로, 복제본 이름을 그대로 찾게 하려고 일부러 패치하지
    않기 때문이다. 그래서 **서울이 살아 있는 동안** 도쿄 collector 가 같이 돌면
    같은 열쇠로 호출량이 2배가 되고, 한도에 걸리면 운영 수집이 실패해 판정
    목표 #6(수집 신선도)·#7(수집→가공 p95)이 깨진다. 운영 스케줄은
    collector-tide */10(10분마다) · collector-bulletin-season 매시간이다.

    실제 리전 장애 때는 서울이 죽어 있어 2배가 되지 않는다 — 그때는 이 값을
    false 로 주고 승격한다(DR 페일오버 런북 단계). 기본값을 true(멈춤)로 둔
    것은, 실수로 운영 수집을 깨뜨리는 쪽이 도쿄 수집이 한 주기 늦는 쪽보다
    훨씬 위험하기 때문이다.

    공공 API 를 쓰지 않는 CronJob(evaluation-sweep · interpolation-error ·
    raw-coverage · web/ocean-fetch)은 다른 Application 이라 이 값과 무관하게
    계속 돈다 — 도쿄 복구 상태를 지표로 확인하려면 그쪽은 켜 둬야 한다.
  EOT
  type        = bool
  default     = true
}

variable "gitops_revision" {
  description = "Argo CD 가 읽을 gitops 브랜치 — root(하위 앱 12개)와 Terraform 앱 9개가 같이 따른다. 시험 구역 · 브랜치 미리보기 때만 바꾼다."
  type        = string
  default     = "main"
}
