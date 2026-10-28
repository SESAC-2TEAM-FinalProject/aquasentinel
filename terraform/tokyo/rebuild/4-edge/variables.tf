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
  description = "bootstrap output.tfstate_bucket_name 값(서울 리전 버킷을 그대로 참조). 2-cluster/persistent state를 읽기 위해 필요."
  type        = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}

# (2026-10-20 리전 대조) 서울에만 있던 가드. aws-dns 모듈은 ALB 를 못 찾으면
# 헬스체크·레코드를 **에러 없이 건너뛴다** — 가드가 없으면 4-edge apply 가
# 성공하는데 페일오버 레코드가 안 생기고, 아무도 그걸 모른다. 도쿄는 지운
# 상태에서 4단계를 연달아 돌리는 경로라 이 자리를 실제로 탄다.
variable "require_alb" {
  description = "true면 Gateway ALB를 못 찾을 때 apply를 실패시킨다. destroy 등 ALB가 없는 게 정상인 작업에서만 false로 준다."
  type        = bool
  default     = true
}

# 🔴 2026-10-28 신설 — 훈련에서 **운영 도메인 SECONDARY 를 안 만들기** 위해서다.
#
# 기본값은 서울 PRIMARY 와 같은 세 호스트다(실제 리전 장애 때는 운영 도메인도
# 다 넘어가야 하므로 **그대로 둔다** — 2026-10-27 설계 의도).
#
# 🔴 그런데 훈련은 (나)안이라 `dr-drill.` **하나만** 넘긴다(계획서 8.1). 운영
# 도메인 SECONDARY 는 훈련 내내 **한 번도 쓰이지 않는데**, 떠 있는 동안
# 서울 운영 헬스체크(f9f9a297)가 잠깐이라도 흔들리면 **진짜 사용자가 도쿄로
# 간다**. 의도한 전환이 아니고, 계획서 8.1 의 「#1·#2·#3 어느 것도 떨어뜨리지
# 않는다」는 약속에 구멍이 된다.
#
# 그래서 훈련에서는 빈 목록을 준다:
#
#     terraform apply -var 'failover_hostnames=[]'
#
# 🔸 `dr-drill` SECONDARY 는 이 값과 **무관하다** — 모듈이 drill_hostnames 로
#    따로 만든다(modules/aws-dns/main.tf 198행). 즉 훈련에 필요한 것은 다 생긴다.
variable "failover_hostnames" {
  description = "운영 failover SECONDARY 를 만들 호스트 목록. 🔴 훈련에서는 [] 를 준다 — dr-drill 은 영향 없다."
  type        = list(string)
  default     = ["", "auth", "grafana"]
}
