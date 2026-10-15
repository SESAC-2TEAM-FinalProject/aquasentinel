# 트랙 B(클러스터 밖 경로) 감지 쪽 — Route53 헬스체크 2개와 CloudWatch 알람 2개.
#
# 헬스체크 두 종류의 차이:
#   - edge_tcp 알람: module.dns 안의 TCP 443 헬스체크 — ALB 리스너(리스닝 여부)만 본다.
#     리전 전체 장애 감지에 쓴다.
#   - edge_readyz 알람: 아래 HTTPS /readyz 헬스체크 — DB 연결 등 앱 내부 상태를 확인한다.
#     ALB는 떠 있지만 503을 내는 부분 장애(10/13 DB 장애 사례)를 감지한다.
#
# 알람이 us-east-1에 있는 이유: Route53 HealthCheckStatus 지표가 us-east-1에만 쌓인다.
#
# 감지 시간: 30초 × 3회 실패 + 1분 × 2회 평가 ≈ 3~4분 — RTO의 "감지" 구간 하한.

# ---------------------------------------------------------------------------
# ALB 미발견 시 apply 실패
# ---------------------------------------------------------------------------

resource "terraform_data" "require_alb" {
  lifecycle {
    precondition {
      condition     = !var.require_alb || module.dns.alb_dns_name != null
      error_message = "Gateway ALB를 찾지 못했다 — 3-gitops 적용과 ALB 생성을 먼저 확인. 의도한 것이면 -var require_alb=false."
    }
  }
}

# ---------------------------------------------------------------------------
# HTTPS /readyz 헬스체크
# ---------------------------------------------------------------------------

# /readyz는 DB 연결을 확인한다 — TCP 헬스체크는 ALB 리스너만 보므로 DB 장애로
# status-svc가 503을 내도 정상으로 본다(10/13 장애).
# Failover 레코드에는 연결하지 않는다(감시 전용) — 연결하면 DB 장애가 리전 전환을 일으킨다.
resource "aws_route53_health_check" "readyz" {
  fqdn              = data.terraform_remote_state.persistent.outputs.domain_name
  port              = 443
  type              = "HTTPS"
  resource_path     = "/readyz"
  request_interval  = 30
  failure_threshold = 3
  enable_sni        = true

  tags = {
    Name = "${local.name_prefix}-readyz-healthcheck"
  }
}

# ---------------------------------------------------------------------------
# CloudWatch 알람 2개 — 둘 다 us-east-1
# ---------------------------------------------------------------------------

# treat_missing_data = "missing"인 이유: 알람을 처음 만든 직후에는 데이터가 없어서,
# "breaching"이면 생성하자마자 ALARM 메일이 나간다.

resource "aws_cloudwatch_metric_alarm" "edge_tcp" {
  provider = aws.us_east_1

  alarm_name        = "${local.name_prefix}-edge-tcp"
  alarm_description = "ALB 리스너(443)가 응답하지 않음 = 진입점·리전 장애. 확인: ALB 상태, EKS 클러스터."

  namespace   = "AWS/Route53"
  metric_name = "HealthCheckStatus"

  dimensions = {
    HealthCheckId = module.dns.health_check_id
  }

  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"

  alarm_actions = [data.terraform_remote_state.persistent.outputs.alerts_global_topic_arn]
  ok_actions    = [data.terraform_remote_state.persistent.outputs.alerts_global_topic_arn]

  depends_on = [terraform_data.require_alb]
}

resource "aws_cloudwatch_metric_alarm" "edge_readyz" {
  provider = aws.us_east_1

  alarm_name        = "${local.name_prefix}-edge-readyz"
  alarm_description = "/readyz 실패 = 서비스는 떠 있지만 DB 연결 불가 등으로 503. 확인: kubectl get pods -n web -l app=status-svc, CNPG 상태."

  namespace   = "AWS/Route53"
  metric_name = "HealthCheckStatus"

  dimensions = {
    HealthCheckId = aws_route53_health_check.readyz.id
  }

  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"

  alarm_actions = [data.terraform_remote_state.persistent.outputs.alerts_global_topic_arn]
  ok_actions    = [data.terraform_remote_state.persistent.outputs.alerts_global_topic_arn]

  depends_on = [terraform_data.require_alb]
}
