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

# 도쿄 전용 — 자기 백업을 쓰는 경로. 위 prefix(서울 백업 복제본을 읽는 경로)와
# 갈라 둔 이유는 main.tf 의 local 주석이 본문이다.
output "cloudnativepg_write_prefix" {
  value = local.cloudnativepg_write_prefix
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
