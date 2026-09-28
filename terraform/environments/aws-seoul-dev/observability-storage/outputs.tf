output "bucket_name" {
  value = module.observability_storage.bucket_name
}

output "bucket_arn" {
  value = module.observability_storage.bucket_arn
}

output "thanos_role_arn" {
  value = module.observability_storage.thanos_role_arn
}

output "loki_role_arn" {
  value = module.observability_storage.loki_role_arn
}

output "cloudnativepg_backup_role_arn" {
  value = module.observability_storage.cloudnativepg_backup_role_arn
}

output "thanos_prefix" {
  value = module.observability_storage.thanos_prefix
}

output "loki_bucket_name" {
  value = module.observability_storage.loki_bucket_name
}

output "cloudnativepg_prefix" {
  value = module.observability_storage.cloudnativepg_prefix
}
