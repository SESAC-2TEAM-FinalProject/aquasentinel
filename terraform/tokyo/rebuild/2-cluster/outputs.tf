output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "cluster_security_group_id" {
  value = module.eks.cluster_security_group_id
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  value = module.eks.oidc_provider_url
}

output "redis_endpoint" {
  value = module.data.redis_endpoint
}

output "redis_port" {
  value = module.data.redis_port
}

output "lbc_role_arn" {
  value = module.lbc_irsa.role_arn
}

output "eso_role_arn" {
  value = module.eso_irsa.role_arn
}

output "thanos_role_arn" {
  value = module.thanos_irsa.role_arn
}

output "loki_role_arn" {
  value = module.loki_irsa.role_arn
}

output "cloudnativepg_role_arn" {
  value = module.cloudnativepg_irsa.role_arn
}

output "collector_role_arn" {
  value = module.collector_irsa.role_arn
}

output "processor_role_arn" {
  value = module.processor_irsa.role_arn
}
