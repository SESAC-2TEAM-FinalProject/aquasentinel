output "bucket_arns" {
  value = module.storage.bucket_arns
}

output "bucket_names" {
  value = module.storage.bucket_names
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
