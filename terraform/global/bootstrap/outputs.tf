output "tfstate_bucket_name" {
  description = "각 environment/*/*/backend.hcl 의 bucket 값으로 그대로 사용한다."
  value       = aws_s3_bucket.tfstate.id
}

output "tfstate_bucket_region" {
  value = var.bootstrap_region
}

# 잠금(lock)은 Terraform >= 1.10의 S3 네이티브 락 기능(backend의 use_lockfile = true)을 쓴다.
# 별도 DynamoDB 테이블이 필요 없다. 팀이 기존 DynamoDB 락 방식에 더 익숙하면
# 이 파일에 aws_dynamodb_table을 추가하고 각 backend.hcl에 dynamodb_table 값을 넣는 것으로 대체 가능.

output "tfstate_replica_bucket_name" {
  description = <<-EOT
    DR 때 backend.hcl 의 bucket 값으로 바꿔 넣을 이름. 🔴 원본과 이름이 다르므로
    region 만 바꾸면 안 된다 — `scripts/dr-switch-tfstate-backend.sh` 가 둘 다 바꾼다.
  EOT
  value       = var.enable_tfstate_replication ? aws_s3_bucket.tfstate_replica[0].id : null
}

output "tfstate_replica_bucket_region" {
  value = var.enable_tfstate_replication ? var.tfstate_replica_region : null
}
