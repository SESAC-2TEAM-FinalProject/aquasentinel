output "certificate_arn" {
  description = "검증 완료된 인증서 ARN. 나중에 Ingress 어노테이션(alb.ingress.kubernetes.io/certificate-arn)에 그대로 쓴다."
  value       = aws_acm_certificate_validation.this.certificate_arn
}

output "zone_id" {
  value = data.aws_route53_zone.this.zone_id
}

output "domain_name" {
  value = var.domain_name
}
