# 트랙 B(클러스터 밖 경로) 수신 쪽 — SNS 토픽 2개와 이메일 구독, ACM 만료 알람.
#
# 토픽이 두 리전에 나뉘는 이유:
#   - Route53 헬스체크 지표(AWS/Route53 HealthCheckStatus)는 us-east-1에만 쌓인다.
#     → alerts_global 토픽과 헬스체크 알람은 us-east-1에 있어야 한다.
#   - ACM 만료 지표(AWS/CertificateManager DaysToExpiry)는 인증서가 있는 리전(서울)에 쌓인다.
#     → alerts_regional 토픽과 ACM 알람은 서울에 있어야 한다.
#
# persistent에 두는 이유: rebuild 계층에 두면 재구축마다 토픽이 새로 생겨
# 구독 확인 메일을 다시 눌러야 한다. SNS 구독은 한 번 확인하면 유지되어야 한다.

# ---------------------------------------------------------------------------
# SNS 토픽
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alerts_global" {
  provider = aws.us_east_1

  name = "${local.name_prefix}-alerts-global"
}

resource "aws_sns_topic" "alerts_regional" {
  name = "${local.name_prefix}-alerts-regional"
}

# ---------------------------------------------------------------------------
# 이메일 구독
# ---------------------------------------------------------------------------

resource "aws_sns_topic_subscription" "alerts_global_email" {
  provider = aws.us_east_1

  for_each = toset(var.alarm_email_endpoints)

  topic_arn = aws_sns_topic.alerts_global.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "alerts_regional_email" {
  for_each = toset(var.alarm_email_endpoints)

  topic_arn = aws_sns_topic.alerts_regional.arn
  protocol  = "email"
  endpoint  = each.value
}

# ---------------------------------------------------------------------------
# ACM 만료 알람
# ---------------------------------------------------------------------------

# 서울에 인증서가 여러 개(과거 재구축분) 있지만 현재 인증서 하나만 대상으로 한다.
# 안 쓰는 옛 인증서는 자동 갱신되지 않아 전체를 대상으로 하면 언젠가 오탐한다.
resource "aws_cloudwatch_metric_alarm" "acm_expiry" {
  alarm_name        = "${local.name_prefix}-acm-expiry"
  alarm_description = "DNS 검증 인증서는 만료 약 60일 전부터 자동 갱신된다. 30일 미만이면 갱신이 실패한 것. 확인: ACM 콘솔의 갱신 상태, Route53 검증 CNAME."

  namespace   = "AWS/CertificateManager"
  metric_name = "DaysToExpiry"

  dimensions = {
    CertificateArn = module.dns.certificate_arn
  }

  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 30
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts_regional.arn]
  ok_actions    = [aws_sns_topic.alerts_regional.arn]
}
