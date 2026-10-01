locals {
  name_prefix               = "${var.project_name}-${var.environment}"
  subject_alternative_names = var.include_wildcard_san ? ["*.${var.domain_name}"] : []
}

# 이미 존재하는 Hosted Zone을 조회만 한다 — Terraform이 이 zone을 소유/관리하지
# 않으므로 zone 자체의 다른 레코드에는 전혀 영향을 주지 않는다.
data "aws_route53_zone" "this" {
  name = var.domain_name
}

# ACM 인증서는 리전 종속 리소스라 (ALB와 같은 리전에 있어야 함),
# 서울/도쿄 environment가 각자 자기 리전에 별도로 하나씩 발급받는다.
resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name
  subject_alternative_names = local.subject_alternative_names
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-cert"
  })
}

# 서울·도쿄가 같은 도메인에 대해 각각 인증서를 요청하면 검증용 CNAME 레코드
# 이름이 겹칠 수 있다. allow_overwrite = true로 두 environment가 같은 zone에
# 동시에 apply해도 "already exists" 충돌 없이 수렴하게 한다.
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# Gateway API ALB는 Terraform이 만들지 않는다(GitOps가 k8s Gateway 리소스로
# 생성, AWS LBC가 리컨사일). 그 ALB를 AWS LBC가 자동으로 붙이는 트래킹 태그로
# 조회한다 — 태그 키는 kubernetes-sigs/aws-load-balancer-controller의
# pkg/gateway/constants.ALBGatewayTagPrefix("gateway.k8s.aws.alb")와
# pkg/deploy/tracking/provider.go의 StackID(= "<namespace>/<gateway이름>")
# 규칙을 따른다.
data "aws_lbs" "gateway" {
  count = var.enable_failover_routing ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster"     = var.cluster_name
    "gateway.k8s.aws.alb/stack" = "${var.gateway_namespace}/${var.gateway_name}"
  }
}

data "aws_lb" "gateway" {
  count = var.enable_failover_routing ? 1 : 0

  arn = tolist(data.aws_lbs.gateway[0].arns)[0]
}

# PRIMARY 리전(서울)에만 켠다 — Failover 레코드가 이 결과를 따라 서울/도쿄를
# 전환한다.
resource "aws_route53_health_check" "alb" {
  count = var.enable_health_check ? 1 : 0

  fqdn              = data.aws_lb.gateway[0].dns_name
  port              = 443
  type              = "HTTPS"
  resource_path     = var.health_check_path
  failure_threshold = 3
  request_interval  = 30

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-alb-healthcheck"
  })
}

# 같은 zone·같은 이름(apex)에 서울/도쿄가 각자 자기 레코드를 set_identifier로
# 구분해서 등록한다 — PRIMARY(서울)는 health_check_id로 위 헬스체크를 참조하고,
# SECONDARY(도쿄)는 헬스체크 없이 "PRIMARY가 죽으면 응답"으로만 동작한다.
resource "aws_route53_record" "failover" {
  count = var.enable_failover_routing ? 1 : 0

  zone_id = data.aws_route53_zone.this.zone_id
  name    = var.domain_name
  type    = "A"

  set_identifier = var.environment

  failover_routing_policy {
    type = var.failover_role
  }

  health_check_id = var.enable_health_check ? aws_route53_health_check.alb[0].id : null

  alias {
    name                   = data.aws_lb.gateway[0].dns_name
    zone_id                = data.aws_lb.gateway[0].zone_id
    evaluate_target_health = true
  }
}
