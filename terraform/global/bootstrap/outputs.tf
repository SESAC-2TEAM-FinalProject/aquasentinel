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
