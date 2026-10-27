variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "create_certificate" {
  description = "true면 ACM 인증서를 발급한다(persistent 컴포넌트). false면 다른 호출(4-edge)이 이미 만든 인증서가 있다고 가정하고 이 모듈은 레코드만 다룬다."
  type        = bool
  default     = true
}

variable "domain_name" {
  description = "이미 Route53에 존재하는 Hosted Zone 이름 (apex 그대로 사용). 나중에 프로젝트 전용 도메인을 구매하면 이 값만 바꾸면 된다."
  type        = string
}

variable "include_wildcard_san" {
  description = "true면 *.domain_name도 SAN에 포함해 Grafana·Argo CD 등 서브도메인 노출을 대비한다."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "enable_failover_routing" {
  description = "true면 이 리전의 Gateway API ALB를 Route53 Failover 레코드(apex, alias)로 등록한다. 서울/도쿄 둘 다 true로 두고 failover_role로만 구분한다."
  type        = bool
  default     = false
}

variable "failover_hostnames" {
  description = "Failover 레코드를 만들 호스트 이름 목록. \"\"는 apex(루트 도메인), 나머지는 서브도메인 prefix(예: \"auth\" → auth.<domain_name>). enable_failover_routing=true일 때만 사용."
  type        = list(string)
  default     = [""]
}

variable "failover_role" {
  description = "PRIMARY 또는 SECONDARY. enable_failover_routing=true일 때만 사용 — 서울=PRIMARY, 도쿄=SECONDARY."
  type        = string
  default     = "SECONDARY"

  validation {
    condition     = contains(["PRIMARY", "SECONDARY"], var.failover_role)
    error_message = "failover_role은 PRIMARY 또는 SECONDARY여야 한다."
  }
}

variable "enable_health_check" {
  description = "true면 이 리전 ALB에 Route53 헬스체크를 만들어 PRIMARY 레코드에 연결한다. 서울(PRIMARY)에만 켠다 — 도쿄는 헬스체크 없이 PRIMARY 장애 시에만 응답."
  type        = bool
  default     = false
}

variable "health_check_path" {
  description = "헬스체크 HTTP(S) 경로. 대시보드 앱의 health/readiness 엔드포인트가 정해지면 그 값으로 바꾼다."
  type        = string
  default     = "/"
}

variable "cluster_name" {
  description = "이 리전 EKS 클러스터 이름 — AWS LBC가 ALB에 붙이는 elbv2.k8s.aws/cluster 태그값과 매칭해 ALB를 조회한다. enable_failover_routing=true일 때 필수."
  type        = string
  default     = null
}

variable "gateway_namespace" {
  description = "Gateway API Gateway 리소스의 네임스페이스 (manifests/gateway-api/gateway.yaml 기준)."
  type        = string
  default     = "ingress"
}

variable "gateway_name" {
  description = "Gateway API Gateway 리소스 이름 (manifests/gateway-api/gateway.yaml 기준)."
  type        = string
  default     = "aquasentinel-gw"
}

# ---------------------------------------------------------------------------
# 훈련(DR 드릴) 전용 — 2026-10-27
#
# 운영 레코드(failover_hostnames)와 **헬스체크를 공유하지 않는다**. 공유하면
# 뒤집는 순간 aquasentinel.cloud · auth. · grafana. 가 전부 같이 넘어간다.
# DR 테스트 계획서 8.1 의 "드릴 전용 헬스체크가 #1 판정에 쓰는 헬스체크와
# 섞이지 않아야 한다"가 이 분리를 요구한다.
# ---------------------------------------------------------------------------

variable "drill_hostnames" {
  description = "훈련 전용 failover 레코드를 만들 서브도메인 prefix 목록(예: [\"dr-drill\"]). 빈 목록이면 아무것도 만들지 않는다 — 평상시 기본값이다."
  type        = list(string)
  default     = []

  validation {
    # apex("")를 넣으면 운영 apex 레코드와 같은 이름·같은 set_identifier 가 되어
    # 서로 덮어쓴다. 훈련 호스트는 반드시 서브도메인이어야 한다.
    condition     = !contains(var.drill_hostnames, "")
    error_message = "drill_hostnames 에 \"\"(apex)는 넣을 수 없다 — 운영 apex 레코드와 충돌한다."
  }
}

variable "drill_health_check_inverted" {
  description = <<-EOT
    🔴 훈련 스위치. true 면 드릴 전용 헬스체크의 판정을 **뒤집어** PRIMARY 를
    "죽은 것"으로 만든다 → drill_hostnames 의 레코드만 SECONDARY(도쿄)로 넘어간다.

    ALB·파드·운영 레코드는 **하나도 건드리지 않는다** — 뒤집히는 것은 이
    헬스체크의 판정뿐이다. 전환까지 걸리는 시간은 request_interval 30초 ×
    failure_threshold 3 = **약 90초** + ALIAS 캐시(최대 60초).

    🔴 기본값은 false 다. true 로 머지하면 머지 즉시 전환이 걸린다.
  EOT
  type        = bool
  default     = false
}
