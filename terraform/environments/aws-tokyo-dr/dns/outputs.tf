output "certificate_arn" {
  value = module.dns.certificate_arn
}

output "domain_name" {
  value = module.dns.domain_name
}

output "zone_id" {
  value = module.dns.zone_id
}

output "alb_dns_name" {
  value = module.dns.alb_dns_name
}
