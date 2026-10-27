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

variable "seoul_region" {
  description = "피어링 상대 리전. 수락(accepter)과 서울 라우트를 이 리전에 만든다."
  type        = string
  default     = "ap-northeast-2"
}

# 🔴 서울 라우트 테이블을 이름으로 찾기 위해 필요하다. aws-network 모듈이
# "${project_name}-${environment}-private-rt-N" 으로 짓는데, 서울의
# environment 는 "dev" 라 이 컴포넌트의 var.environment("dr-tokyo")로는
# 못 만든다. 서울 1-network outputs 에 name_prefix 가 없어 변수로 받는다.
variable "seoul_name_prefix" {
  description = "서울 리소스 이름 접두사. 서울 private 라우트 테이블을 tag:Name 으로 찾는 데 쓴다."
  type        = string
  default     = "aquasentinel-dev"
}

variable "tfstate_bucket" {
  description = "bootstrap output.tfstate_bucket_name 값(서울 리전 버킷). 양 리전 1-network state 를 읽기 위해 필요."
  type        = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}

# 🔴 2부 2단계 「스트리밍 끊기」 스위치다(계획서 2.3).
#
#   끊는 방법을 **도쿄 라우트 삭제**로 정한 이유는 서울을 건드리지 않기
#   때문이다 — 판정 창 안 서울 변경이 아니다. 여기를 false 로 주고 apply 하면
#   도쿄 → 서울 경로만 사라지고, 서울 쪽 라우트와 피어링 자체는 남는다.
#   다시 true 로 주면 되돌아온다.
#
#   🔸 훈련 중에는 apply 를 기다리기보다 AWS CLI 로 라우트만 지우는 쪽이
#      빠를 수 있다. 그 경우 끝난 뒤 이 값과 실물이 어긋나므로, 되돌린 뒤
#      반드시 plan 으로 "No changes" 를 확인한다.
variable "enable_tokyo_route" {
  description = "false 면 도쿄 라우트 테이블에서 서울 CIDR 경로를 뺀다 — 2부 스트리밍 끊기."
  type        = bool
  default     = true
}
