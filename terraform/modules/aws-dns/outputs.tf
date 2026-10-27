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
  description = "enable_health_check=false거나 ALB가 아직 없으면 null."
  value       = one(aws_route53_health_check.alb[*].id)
}

output "alb_dns_name" {
  description = "enable_failover_routing=false거나 ALB가 아직 없으면 null."
  value       = one(data.aws_lb.gateway[*].dns_name)
}

output "drill_health_check_id" {
  description = "훈련 전용 헬스체크 ID. drill_hostnames 가 비었거나 enable_health_check=false 면 null — 뒤집기 전에 이 값으로 대상을 확인한다."
  value       = one(aws_route53_health_check.drill[*].id)
}

output "drill_fqdns" {
  description = "만들어진 훈련 전용 레코드의 전체 이름 목록."
  value       = values(local.drill_records)
}
