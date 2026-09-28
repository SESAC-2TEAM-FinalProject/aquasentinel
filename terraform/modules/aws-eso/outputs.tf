output "role_arn" {
  description = "Helm values의 serviceAccount.annotations.\"eks.amazonaws.com/role-arn\"에 그대로 넣는다."
  value       = aws_iam_role.this.arn
}
