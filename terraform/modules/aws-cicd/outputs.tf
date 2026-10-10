output "plan_role_arn" {
  description = "MR/브랜치 파이프라인(plan 전용, 읽기전용)에서 GitLab OIDC로 assume하는 IAM Role ARN. .gitlab-ci.yml에서 AWS_ROLE_ARN으로 그대로 사용."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "main 브랜치 push 파이프라인(apply 전용, 쓰기 권한)에서 GitLab OIDC로 assume하는 IAM Role ARN. .gitlab-ci.yml에서 AWS_ROLE_ARN으로 그대로 사용."
  value       = aws_iam_role.apply.arn
}
