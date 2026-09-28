output "bucket_name" {
  value = module.api_raw_store.bucket_name
}

output "bucket_arn" {
  value = module.api_raw_store.bucket_arn
}

output "collector_role_arn" {
  value = module.api_raw_store.collector_role_arn
}

output "processor_role_arn" {
  value = module.api_raw_store.processor_role_arn
}
