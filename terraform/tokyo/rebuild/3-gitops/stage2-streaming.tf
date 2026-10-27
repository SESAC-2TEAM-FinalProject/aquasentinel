# Stage 2 — 도쿄가 서울 Primary 에 직접 붙게 한다 (2026-10-27)
#
# 무엇이 바뀌나
#   도쿄 Cluster 의 externalClusters[0] 에 connectionParameters 와 TLS 참조
#   3종을 **더한다**. plugin(barman-cloud) 은 **그대로 둔다** — 스트리밍이
#   끊겼을 때 CNPG 가 S3 아카이브로 폴백하도록 두 경로를 다 열어 두는 것이
#   CNPG 권장 구성이다. 2부에서 라우트를 끊으면 바로 이 폴백이 동작한다.
#
# 🔴 왜 인증서가 필요한가
#   서울 pg_hba.conf 실측(2026-10-27):
#     hostssl replication streaming_replica all cert map=cnpg_streaming_replica
#   **클라이언트 인증서 인증**이다. 비밀번호로는 못 붙는다.
#
# 🔴 그 인증서는 Terraform 이 넣지 않는다 — 런북 단계다
#   서울 aquasentinel-pg-ca · aquasentinel-pg-replication 은 CNPG 가 만든
#   쿠버네티스 시크릿이다. 리전을 넘겨야 하는데, 2부 한 번 쓰자고 서울에
#   PushSecret 을 새로 만드는 것은 **창 안 운영 변경**이 하나 더 느는 일이다.
#   인증서 만료가 2027-01-11 이라 훈련 기간에 회전하지 않으므로 **훈련 때
#   1회 복사**로 충분하다. 절차는 runbooks/Stage2_스트리밍_붙이기.md.
#
#   → 그래서 여기서는 **이름만 가리킨다.** 시크릿이 없으면 CNPG 가 Ready 가
#     되지 않으며, 그것이 "복사를 빠뜨렸다"는 신호다.

data "aws_lb" "seoul_pg" {
  # 🔴 enable_stage2_streaming 이 false 면 조회 자체를 하지 않는다.
  #   1부(Stage 0)에는 이 NLB 가 **없기 때문**이다. count 가 없으면 1부
  #   apply 가 "load balancer not found" 로 멈춘다.
  count    = var.enable_stage2_streaming && var.seoul_pg_host_override == "" ? 1 : 0
  provider = aws.seoul

  name = var.seoul_pg_nlb_name
}

locals {
  # one() 은 비어 있으면 에러가 아니라 null 을 준다 — count = 0 일 때 안전하다.
  seoul_pg_host = (
    var.seoul_pg_host_override != ""
    ? var.seoul_pg_host_override
    : one(data.aws_lb.seoul_pg[*].dns_name)
  )

  # 평소(Stage 0) — S3 로그 수송만. 공식 예제 cluster-replica-log-shipping.yaml.
  _external_cluster_log_shipping = jsonencode({
    name = "seoul"
    plugin = {
      name = "barman-cloud.cloudnative-pg.io"
      parameters = {
        barmanObjectName = "aquasentinel-pg-seoul-source"
        serverName       = "aquasentinel-pg"
      }
    }
  })

  # Stage 2 — 위에 직접 접속을 **더한** 것. cluster-replica-streaming.yaml 꼴.
  _external_cluster_streaming = jsonencode({
    name = "seoul"
    plugin = {
      name = "barman-cloud.cloudnative-pg.io"
      parameters = {
        barmanObjectName = "aquasentinel-pg-seoul-source"
        serverName       = "aquasentinel-pg"
      }
    }
    connectionParameters = {
      host    = local.seoul_pg_host
      user    = "streaming_replica"
      dbname  = "postgres"
      sslmode = var.seoul_pg_sslmode
    }
    sslKey = {
      name = var.seoul_replication_secret_name
      key  = "tls.key"
    }
    sslCert = {
      name = var.seoul_replication_secret_name
      key  = "tls.crt"
    }
    sslRootCert = {
      name = var.seoul_ca_secret_name
      key  = "ca.crt"
    }
  })

  # 🔴 jsonencode → 문자열 삼항 → jsondecode 로 돌아가는 이유
  #   Terraform 의 삼항은 양쪽 **타입이 같아야** 한다. 위 두 객체는 속성 수가
  #   달라 객체끼리 바로 고르면 "inconsistent types" 로 막힌다. 문자열로
  #   바꿔 고르고 다시 풀면 그 제약을 피한다.
  seoul_external_clusters = [
    jsondecode(
      var.enable_stage2_streaming
      ? local._external_cluster_streaming
      : local._external_cluster_log_shipping
    )
  ]
}

# 켠 채로 호스트를 못 구하면 조용히 null 이 들어가 CNPG 가 이상한 곳에 붙으려
# 한다. 그 전에 멈춘다.
resource "terraform_data" "stage2_streaming_guard" {
  count = var.enable_stage2_streaming ? 1 : 0

  lifecycle {
    precondition {
      condition     = local.seoul_pg_host != null && local.seoul_pg_host != ""
      error_message = "enable_stage2_streaming = true 인데 서울 Postgres 호스트를 못 구했다 — gitops 의 pg-rw-internal-nlb.yaml 을 kustomization.yaml 에 올려 NLB 를 먼저 띄우거나, seoul_pg_host_override 를 직접 주라."
    }
  }
}

output "stage2_streaming_enabled" {
  description = "도쿄가 서울에 직접 붙는 설정이 켜져 있는가."
  value       = var.enable_stage2_streaming
}

output "stage2_seoul_host" {
  description = "도쿄가 붙을 서울 Postgres 호스트. 꺼져 있으면 null."
  value       = local.seoul_pg_host
}
