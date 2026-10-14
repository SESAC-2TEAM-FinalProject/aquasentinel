output "runner_role_arn" {
  value = aws_iam_role.runner.arn
}

output "autoscaling_group_name" {
  value = aws_autoscaling_group.runner.name
}

output "security_group_id" {
  value = aws_security_group.runner.id
}
