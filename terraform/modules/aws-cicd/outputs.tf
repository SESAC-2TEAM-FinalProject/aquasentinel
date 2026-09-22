output "plan_role_arn" {
  description = "PR 등에서 terraform plan 시 role-to-assume으로 사용."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "main 브랜치 merge 시 terraform apply에서 role-to-assume으로 사용."
  value       = aws_iam_role.apply.arn
}
