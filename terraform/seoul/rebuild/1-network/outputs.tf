# 아래 전부 2-cluster가 data.terraform_remote_state.network로 읽어가는 값들이다
# (subnet_ids는 EKS 노드그룹/control plane 배치에, vpc_id는 Redis 보안그룹에 쓰임).

output "vpc_id" {
  value = module.network.vpc_id
}

output "vpc_cidr" {
  value = module.network.vpc_cidr
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "private_app_subnet_ids" {
  value = module.network.private_app_subnet_ids
}

output "private_data_subnet_ids" {
  value = module.network.private_data_subnet_ids
}
