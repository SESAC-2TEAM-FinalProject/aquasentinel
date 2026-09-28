output "eso_role_arn" {
  description = "aquasentinel-gitops의 apps/external-secrets/application.yaml 플레이스홀더에 채워 넣는다."
  value       = module.eso.role_arn
}
