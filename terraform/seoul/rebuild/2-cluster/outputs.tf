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

output "gitlab_runner_build_role_arn" {
  value = module.gitlab_runner_irsa.role_arn
}

output "karpenter_controller_role_arn" {
  value = module.karpenter_irsa.role_arn
}

output "karpenter_node_instance_profile_name" {
  value = module.eks.node_instance_profile_name
}

output "karpenter_node_role_name" {
  value = module.eks.node_role_name
}

output "karpenter_interruption_queue_name" {
  value = aws_sqs_queue.karpenter_interruption.name
}

# 아래 둘은 카펜터 EC2NodeClass/NodePool(3-gitops/karpenter.tf)이 기존
# 관리형 노드그룹과 같은 인스턴스 타입·max-pods 값을 쓰도록 재사용한다 —
# 같은 값을 3-gitops 변수로 또 선언하면 두 곳을 손으로 맞춰야 하는 중복이 생긴다.
output "node_instance_types" {
  value = var.node_instance_types
}

output "max_pods_per_node" {
  value = var.max_pods_per_node
}
