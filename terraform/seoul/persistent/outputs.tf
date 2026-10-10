output "bucket_arns" {
  value = module.storage.bucket_arns
}

output "bucket_names" {
  value = module.storage.bucket_names
}

output "thanos_prefix" {
  value = local.thanos_prefix
}

output "cloudnativepg_prefix" {
  value = local.cloudnativepg_prefix
}

output "repository_urls" {
  value = module.registry.repository_urls
}

output "repository_arns" {
  value = module.registry.repository_arns
}

output "certificate_arn" {
  value = module.dns.certificate_arn
}

output "domain_name" {
  value = module.dns.domain_name
}

output "zone_id" {
  value = module.dns.zone_id
}
