output "plan_role_arn" {
  value = module.cicd.plan_role_arn
}

output "apply_role_arn" {
  value = module.cicd.apply_role_arn
}

output "build_role_arns" {
  value = module.cicd.build_role_arns
}
