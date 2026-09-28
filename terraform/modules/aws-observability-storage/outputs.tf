output "bucket_name" {
  value = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.this.arn
}

output "thanos_role_arn" {
  description = "Helm 설치 시 serviceAccount.annotations.\"eks.amazonaws.com/role-arn\"에 그대로 넣는다."
  value       = aws_iam_role.this["thanos"].arn
}

output "loki_role_arn" {
  description = "Helm 설치 시 serviceAccount.annotations.\"eks.amazonaws.com/role-arn\"에 그대로 넣는다."
  value       = aws_iam_role.loki.arn
}

output "loki_bucket_name" {
  description = "Loki 전용 버킷 — 공유 버킷의 prefix가 아니라 별도 버킷이다(이유는 main.tf 주석 참고)."
  value       = aws_s3_bucket.loki.bucket
}

output "cloudnativepg_backup_role_arn" {
  description = "Barman Cloud 플러그인/ObjectStore CR의 서비스어카운트에 연결한다."
  value       = aws_iam_role.this["cloudnativepg"].arn
}

output "thanos_prefix" {
  value = local.workloads.thanos.prefix
}

output "cloudnativepg_prefix" {
  value = local.workloads.cloudnativepg.prefix
}
