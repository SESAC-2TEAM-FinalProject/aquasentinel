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

output "alerts_global_topic_arn" {
  description = "us-east-1 SNS 토픽 — Route53 헬스체크 알람용(4-edge가 읽는다)."
  value       = aws_sns_topic.alerts_global.arn
}

output "alerts_regional_topic_arn" {
  description = "서울 SNS 토픽 — 서울 리전 지표 알람용(ACM 만료 등)."
  value       = aws_sns_topic.alerts_regional.arn
}
