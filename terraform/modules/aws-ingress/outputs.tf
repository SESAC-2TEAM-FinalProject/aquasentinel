output "role_arn" {
  description = "Helm 설치 시 serviceAccount.annotations.\"eks.amazonaws.com/role-arn\"에 그대로 넣는다."
  value       = aws_iam_role.lbc.arn
}
