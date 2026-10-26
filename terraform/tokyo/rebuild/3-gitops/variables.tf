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

variable "dr_mode" {
  description = <<-EOT
    🔴 도쿄를 **대기 상태**로 띄울지, **전환(승격) 상태**로 띄울지.

      standby — 평상시(기본). 쓰기가 필요한 워크로드를 꺼 둔다.
      active  — 실제 DR 전환. 그 패치들을 빼서 깨운다.

    왜 변수여야 하는가 — 전에는 이 패치들이 코드에 박혀 있어서, 승격하려면
    장애 한가운데서 `applications.tf` 를 **손으로 고쳐야** 했다(MR !71 이
    넣은 주석의 런북 ②③단계가 그 뜻이다). 그 시간이 전부 RTO 에 들어간다.
    이제 `-var dr_mode=active` 한 줄이 그 두 단계를 대신한다.

    standby 에서 꺼 두는 것과 그 이유(2026-10-01 팀 결정 · 2026-10-25 실측)
      - Keycloak `instances: 0` — Replica Cluster 는 `transaction_read_only`
        이고 Keycloak 은 기동 때 스키마를 써야 해 **구조적으로 못 뜬다**
      - 조회 API(web-backend) `replicas: 0` + KEDA ScaledObject 제거 —
        `/readyz` 가 읽기 전용만 확인해서 **쓰기 요청만 조용히 500** 이 된다
      - `api-module-database` PushSecret 제거 — Replica Cluster 는 app 사용자를
        만들지 않아 source Secret 이 **애초에 없어** 영구 실패한다
      - api-module 쓰기 워크로드 정지(2026-10-26 결정 ③ — 「대기 모드에서만
        끈다」) — completeness-check Deployment · processor/grading/
        interpolation/evaluation Rollout + ScaledObject · interpolation-error/
        evaluation-sweep CronJob. 🔴 `raw-coverage` 는 읽기 전용이라 건드리지
        않는다. active 에서는 **반드시 깨워야** 한다 — 신선도 회복이 곧 RTO
        정의이기 때문이다

    🔴 `suspend_collectors` 와는 **다른 축**이다. 이쪽은 "도쿄 DB 가 쓰기
    가능한가", 저쪽은 "서울과 공공 API 열쇠를 동시에 쓰는가"다. 서울이 살아
    있는 채로 하는 훈련에서는 `dr_mode=active` 여도 collector 는 멈춰 둬야
    한다 — 두 변수를 따로 두는 이유다.

    🔴 이 변수가 다루지 않는 것
      - CNPG 승격(`replica.enabled: true→false`) — 런북 ①단계, 데이터가 걸린
        동작이라 일부러 사람이 한다
      - 승격 뒤 비밀번호 맞추기 · Route53 — 런북 ④⑤단계
  EOT
  type        = string
  default     = "standby"

  validation {
    condition     = contains(["standby", "active"], var.dr_mode)
    error_message = "dr_mode 는 standby 또는 active 여야 한다."
  }
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
