output "certificate_arn" {
  value = module.dns.certificate_arn
}

output "zone_id" {
  value = module.dns.zone_id
}

output "health_check_id" {
  value = module.dns.health_check_id
}

output "alb_dns_name" {
  value = module.dns.alb_dns_name
}
