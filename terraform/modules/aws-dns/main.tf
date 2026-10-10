locals {
  name_prefix               = "${var.project_name}-${var.environment}"
  subject_alternative_names = var.include_wildcard_san ? ["*.${var.domain_name}"] : []
}

# 이미 존재하는 Hosted Zone을 조회만 한다 — Terraform이 이 zone을 소유/관리하지
# 않으므로 zone 자체의 다른 레코드에는 전혀 영향을 주지 않는다.
data "aws_route53_zone" "this" {
  name = var.domain_name
}

# ---------------------------------------------------------------------------
# 인증서 — create_certificate=true(persistent 컴포넌트)일 때만 만든다.
# 경로 구조 개편(2026-10-10) 전에는 레코드와 한 컴포넌트에 같이 있어서,
# 레코드가 gitops 적용 뒤에야 가능한 ALB 조회에 의존하는 바람에 인증서까지
# 2단계 적용(TEMP-BOOTSTRAP)이 필요했다. persistent(인증서)/4-edge(레코드)로
# 나누면서 이 문제 자체가 구조적으로 사라진다.
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "this" {
  count = var.create_certificate ? 1 : 0

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
# 이름이 겹칠 수 있다. allow_overwrite = true로 두 persistent가 같은 zone에
# 동시에 apply해도 "already exists" 충돌 없이 수렴하게 한다.
resource "aws_route53_record" "cert_validation" {
  for_each = var.create_certificate ? {
    for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count = var.create_certificate ? 1 : 0

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ---------------------------------------------------------------------------
# 레코드 — enable_failover_routing=true(4-edge 컴포넌트, gitops 뒤)일 때만
# 만든다. Gateway API ALB는 Terraform이 만들지 않는다(GitOps/ArgoCD가 k8s
# Gateway 리소스로 생성, AWS LBC가 리컨사일 — 2-cluster는 LBC의 IRSA Role만
# 만들 뿐 Gateway/ALB 자체는 모른다). 그 ALB를 AWS LBC가 자동으로 붙이는
# 트래킹 태그로 조회한다 — 태그 키는 kubernetes-sigs/aws-load-balancer-controller의
# pkg/gateway/constants.ALBGatewayTagPrefix("gateway.k8s.aws.alb")와
# pkg/deploy/tracking/provider.go의 StackID(= "<namespace>/<gateway이름>")
# 규칙을 따른다.
#
# Terraform이 추적하지 않는 리소스라 ALB가 이미 수동 삭제된 상태에서
# destroy를 돌리면 "empty set"/"empty tuple" 에러로 막혔던 적이 있다
# (2026-10-09). ALB가 안 보이면 조용히 건너뛰도록 try()로 감싸서, "ALB가
# 아직 없거나 이미 사라진" 상태 자체를 정상 케이스로 취급한다.
# ---------------------------------------------------------------------------

data "aws_lbs" "gateway" {
  count = var.enable_failover_routing ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster"     = var.cluster_name
    "gateway.k8s.aws.alb/stack" = "${var.gateway_namespace}/${var.gateway_name}"
  }
}

locals {
  gateway_alb_arn = var.enable_failover_routing ? try(tolist(data.aws_lbs.gateway[0].arns)[0], null) : null
}

data "aws_lb" "gateway" {
  count = local.gateway_alb_arn != null ? 1 : 0

  arn = local.gateway_alb_arn
}

# PRIMARY 리전(서울)에만 켠다 — Failover 레코드가 이 결과를 따라 서울/도쿄를
# 전환한다.
#
# type=TCP(포트 443 리스닝 여부만 확인) — 원래 HTTPS+경로("/")로 ALB 원본
# DNS 이름에 직접 요청했는데, Gateway API는 호스트 기반 라우팅만 처리해서
# 이 Host 헤더와 매칭되는 HTTPRoute가 애초에 존재할 수 없어 항상 404였다
# (실배포 중 발견한 버그, 팀 공유 문서 참고). 리전 전체 장애 감지엔 TCP로
# 충분하다.
resource "aws_route53_health_check" "alb" {
  count = var.enable_health_check && length(data.aws_lb.gateway) > 0 ? 1 : 0

  fqdn              = data.aws_lb.gateway[0].dns_name
  port              = 443
  type              = "TCP"
  failure_threshold = 3
  request_interval  = 30

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-alb-healthcheck"
  })
}

# ""는 apex(루트 도메인, 대시보드), 나머지는 서브도메인(예: "auth"→Keycloak) —
# 전부 같은 ALB(같은 Gateway)를 가리키므로 호스트 이름만 늘어나도 레코드
# 구조는 그대로 재사용한다.
locals {
  # ALB를 못 찾으면(아직 없거나 이미 삭제됨) failover 레코드 자체를 만들지
  # 않는다 — data.aws_lb.gateway가 비어있는데 아래 alias 블록이 참조하면
  # destroy/plan이 깨지기 때문.
  failover_records = var.enable_failover_routing && length(data.aws_lb.gateway) > 0 ? {
    for h in var.failover_hostnames : h => h == "" ? var.domain_name : "${h}.${var.domain_name}"
  } : {}
}

# 같은 zone에 호스트 이름별로 서울/도쿄가 각자 자기 레코드를 set_identifier로
# 구분해서 등록한다 — PRIMARY(서울)는 health_check_id로 위 헬스체크를 참조하고,
# SECONDARY(도쿄)는 헬스체크 없이 "PRIMARY가 죽으면 응답"으로만 동작한다.
resource "aws_route53_record" "failover" {
  for_each = local.failover_records

  zone_id = data.aws_route53_zone.this.zone_id
  name    = each.value
  type    = "A"

  set_identifier = var.environment

  failover_routing_policy {
    type = var.failover_role
  }

  health_check_id = length(aws_route53_health_check.alb) > 0 ? aws_route53_health_check.alb[0].id : null

  alias {
    name                   = data.aws_lb.gateway[0].dns_name
    zone_id                = data.aws_lb.gateway[0].zone_id
    evaluate_target_health = true
  }
}
