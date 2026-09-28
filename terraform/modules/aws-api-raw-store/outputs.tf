output "bucket_name" {
  value = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.this.arn
}

output "collector_role_arn" {
  description = "collector 이미지 serviceAccount.annotations.\"eks.amazonaws.com/role-arn\"에 그대로 넣는다."
  value       = aws_iam_role.collector.arn
}

output "processor_role_arn" {
  description = "processor 이미지(reprocess Job 포함) serviceAccount.annotations.\"eks.amazonaws.com/role-arn\"에 그대로 넣는다."
  value       = aws_iam_role.processor.arn
}
