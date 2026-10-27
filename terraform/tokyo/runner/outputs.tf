output "runner_role_arn" {
  value = aws_iam_role.runner.arn
}

output "autoscaling_group_name" {
  value = aws_autoscaling_group.runner.name
}

output "security_group_id" {
  value = aws_security_group.runner.id
}

output "vpc_id" {
  description = "러너가 사는 도쿄 기본 VPC. 재구축 VPC(10.1.0.0/16)와 다른 것이 정상이다."
  value       = data.aws_vpc.default.id
}
