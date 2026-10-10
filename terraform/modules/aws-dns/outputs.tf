output "certificate_arn" {
  description = "검증 완료된 인증서 ARN. create_certificate=false면 null — 호출하는 쪽이 persistent의 remote_state에서 직접 읽어야 한다."
  value       = var.create_certificate ? aws_acm_certificate_validation.this[0].certificate_arn : null
}

output "zone_id" {
  value = data.aws_route53_zone.this.zone_id
}

output "domain_name" {
  value = var.domain_name
}

output "health_check_id" {
  description = "enable_health_check=false면 null."
  value       = var.enable_health_check ? aws_route53_health_check.alb[0].id : null
}

output "alb_dns_name" {
  description = "enable_failover_routing=false면 null."
  value       = var.enable_failover_routing ? data.aws_lb.gateway[0].dns_name : null
}
