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
      - CNPG 승격(`replica.enabled: true→false`) — 런북 ①단계. 데이터가 걸린
        동작이라 **일부러 이 변수에 묶지 않았다**. 승격은 아래
        `promote_tokyo_db` 를 따로 켜야 일어난다 — `dr_mode=active` 한 줄로
        DB 까지 승격되면 "스위치만 올리면 된다"는 오해가 생긴다
      - 승격 뒤 비밀번호 맞추기 · Route53 — 런북 ④⑤단계
  EOT
  type        = string
  default     = "standby"

  validation {
    condition     = contains(["standby", "active"], var.dr_mode)
    error_message = "dr_mode 는 standby 또는 active 여야 한다."
  }
}

variable "promote_tokyo_db" {
  description = <<-EOT
    🔴 도쿄 CNPG 를 **승격**한다 — 복제본(Replica Cluster) → Primary.
    훈련 **5단계 전용**이고, 되돌릴 수 없는 단계다.

    무엇을 바꾸는가 — applications.tf 의 Cluster 패치에서
    `spec.replica.enabled` 를 `true → false` 로 만든다. `source` 는 CRD 가
    required 라 끈 뒤에도 그대로 둔다(CNPG 가 무시한다).

    🔴 왜 kubectl 이 아니라 변수인가 — 그 Argo Application 의 동기화
    정책이 `automated.selfHeal = true` 라, 손으로 바꾼 값을 Argo 가 원하는
    상태(= 패치에 박힌 true)로 **되돌린다**. 원하는 상태 자체를 바꿔야 한다.

    🔴🔴 4단계(`3-gitops` 첫 apply)에서는 켜지 마라.
      처음부터 false 로 뜨면 도쿄는 **애초에 복제본이 아니게** 된다 — S3
      백업을 한 번 복구하고 거기서 멈추므로 서울을 따라가지 않는다. 그러면
      ⸨1⸩ 5단계(승격)에 잴 것이 없고 ⸨2⸩ 2부 스트리밍이 성립하지 않는다.
      들키는 자리는 5단계의 `pg_is_in_recovery()` 가 이미 f 로 나오는 것이고,
      복구는 도쿄 destroy + S3 잔재 삭제 + 재구축(약 1시간)이다.

    🔴🔴 terraform.tfvars 에 적지 마라 — 모든 apply 에 자동으로
      붙어 위 사고가 난다. **명령줄에서만** 쓴다:

        terraform apply -input=false -var promote_tokyo_db=true

    🔸 5단계 직전에 plan 을 먼저 본다 — `1 to change` 이고 바뀌는 것이
      Cluster 패치 하나여야 한다. 다른 것이 같이 바뀌면 멈추고 확인한다.

    🟢 2026-10-28 리허설에서 **실제로 돌렸고 먹는다**. plan 은
      `0 to add, 1 to change, 0 to destroy` 이고 바뀐 것은
      `patched_app["cloudnativepg-cluster"]` 하나, diff 는 `enabled = true -> false`
      하나였다. apply 뒤 `pg_is_in_recovery()` 가 **28초**에 `f` 로 바뀌고
      `transaction_read_only=off` · 실제 쓰기 성공 · 1분 27초에
      `Cluster in healthy state` 로 안정화됐다. **selfHeal 되돌림은 없었다.**

    🔴🔴 **이 변수는 끈적하지 않다 — 5단계 이후 모든 apply 에 다시 붙여야 한다.**
      기본값이 false 라, 승격한 뒤 플래그를 빼고 apply 하면 plan 이
      `~ enabled = false -> true` 를 내고 **승격이 풀린다**(2026-10-28 리허설에서
      런북 6단계 명령 그대로 재현). 그런데 같은 apply 가 Keycloak 을
      `instances: 1` 로 깨우므로, 읽기 전용이 된 DB 에 스키마를 쓰려다
      **CrashLoop** 이 나고 그 화면이 「도쿄 반영 목록」 #21(비밀번호 불일치)과
      구별되지 않는다. 즉 **증상으로 원인을 못 찾는다.**
        → 6단계 · 2부 재적용 · destroy 까지 전부 `-var promote_tokyo_db=true`.
        → 런북 `DR훈련_당일진행.md` 1장 ② 에 규칙과 plan 확인 절차가 있다.
      🔸 위의 「tfvars 에 적지 마라」와 모순이 아니다 — tfvars 는 **5단계 전**
         사고를, 이 규칙은 **5단계 후** 사고를 막는다. 축이 다르다.
  EOT
  type        = bool
  default     = false
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

variable "drill_hostname" {
  description = <<-EOT
    🔴 DR 훈련(SIM-11) 전용 호스트의 서브도메인 prefix. 웹 HTTPRoute 의
    hostnames 에 **더해서**, 전환 뒤 도쿄에서 그 주소가 응답하게 한다.
    빈 문자열이면 더하지 않는다.

    🔴 **4-edge 의 drill_hostnames 와 같은 값이어야 한다.** 거기서 Route53
    레코드를 만들고 여기서 그 주소를 받는다. 3-gitops 가 4-edge 보다 **먼저**
    돌기 때문에 remote_state 로 끌어올 수 없어 값이 두 곳에 있다. 한쪽만
    고치면 **DNS 는 넘어가는데 화면은 404** 가 된다.

    서울에는 넣지 않는다(결정 ② · 2026-10-27) — 전환 **뒤** 도쿄에서만
    응답하면 되고, 서울 3-gitops apply 를 한 번이라도 줄이기 위해서다.
    🔸 Keycloak 클라이언트의 드릴 주소는 별건으로 **서울에** 들어가 있다
    (7763a2f) — 훈련 중 로그인 서버가 서울이기 때문이고, 호스트 라우팅과는
    다른 이야기다.
  EOT
  type        = string
  default     = "dr-drill"
}

# ───────────────────────────────────────────────────────────────────────────
# Stage 2 — 서울 Primary 에 직접 붙는 스트리밍 복제 (2026-10-27)
#
# 평소(Stage 0)는 서울이 WAL 을 S3 에 올리고 도쿄가 거기서 읽는다.
# archive_timeout 이 5분이라 최대 5분치가 밀린다. Stage 2 는 도쿄가 서울
# Primary 에 TCP 로 직접 붙어 RPO 를 수초로 줄인다.
#
# 🔴 **기본은 꺼짐이다.** 1부(Stage 0)는 이 블록 없이 돌아야 하고, 켜면
#    서울 내부 NLB 가 **이미 떠 있어야** 한다(gitops pg-rw-internal-nlb.yaml).
#    없는 상태에서 켜면 아래 data "aws_lb" 조회가 실패해 apply 가 멈춘다.
# ───────────────────────────────────────────────────────────────────────────

variable "enable_stage2_streaming" {
  description = "true 면 도쿄가 서울 Primary 에 직접 붙는다(Stage 2). false 면 S3 로그 수송만(Stage 0)."
  type        = bool
  default     = false
}

variable "seoul_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "seoul_pg_nlb_name" {
  description = "서울 내부 NLB 이름. gitops pg-rw-internal-nlb.yaml 의 aws-load-balancer-name 주석과 같아야 한다."
  type        = string
  default     = "aquasentinel-dev-pg-rw-internal"
}

# 🔸 NLB 대신 고정 DNS 이름을 쓰고 싶을 때(예: Route53 레코드를 만들어
#    verify-full 로 가는 경우). 비어 있으면 위 NLB 를 조회해서 쓴다.
variable "seoul_pg_host_override" {
  description = "서울 Postgres 접속 호스트를 직접 지정. 비우면 seoul_pg_nlb_name 으로 조회한다."
  type        = string
  default     = ""
}

# 🔴 기본값이 verify-ca 인 이유 — 서울 서버 인증서의 SAN 에 **NLB 이름이 없다**
#    (2026-10-27 실측: aquasentinel-pg-rw.…svc.cluster.local 등 클러스터 안
#    이름만 있다). NLB 주소로 붙으면서 verify-full 을 쓰면 이름이 안 맞아
#    실패한다. verify-ca 는 **우리 CA 로 서명됐는지**는 확인한다 — CNPG 자체
#    CA 라 그 CA 로 서명된 인증서는 우리 클러스터 것뿐이므로 검증 의미가 있다.
#
#    verify-full 로 가려면 서울 spec.certificates.serverAltDNSNames 에 호스트를
#    더해야 하는데, 그건 **서울 인증서 재발급**(창 안 운영 변경)이고 NLB DNS 는
#    만들기 전엔 모른다(임의 접미사). 고정 이름을 쓰려면 Route53 레코드가
#    하나 더 필요하다 — 그 경우 seoul_pg_host_override 와 함께 쓴다.
variable "seoul_pg_sslmode" {
  description = "서울 Postgres 에 붙을 때의 sslmode."
  type        = string
  default     = "verify-ca"

  validation {
    condition     = contains(["verify-ca", "verify-full"], var.seoul_pg_sslmode)
    error_message = "verify-ca 또는 verify-full 만 허용한다 — require/disable 은 서버를 검증하지 않는다."
  }
}

# 🔴 서울에서 복사해 온 인증서가 들어갈 **도쿄 쪽** 시크릿 이름이다.
#    도쿄 CNPG 도 자기 클러스터용으로 aquasentinel-pg-ca ·
#    aquasentinel-pg-replication 을 **스스로 만든다**. 같은 이름을 쓰면
#    충돌하므로 -seoul- 을 끼워 구분한다.
variable "seoul_ca_secret_name" {
  description = "서울 CA(ca.crt)를 담은 도쿄 네임스페이스의 시크릿 이름."
  type        = string
  default     = "aquasentinel-pg-seoul-ca"
}

variable "seoul_replication_secret_name" {
  description = "서울 streaming_replica 클라이언트 인증서(tls.crt·tls.key)를 담은 도쿄 시크릿 이름."
  type        = string
  default     = "aquasentinel-pg-seoul-replication"
}
