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
