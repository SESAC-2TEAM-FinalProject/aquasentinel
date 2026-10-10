# EKS + Access Entry + Redis + 전체 워크로드 IRSA — 전부 "클러스터 수명"에
# 종속되어 재구축 때 같이 사라지는 자원이라 한 컴포넌트로 합쳤다(D2, 경로
# 구조 개편안 2026-10-10). IRSA 정책 내용은 irsa.tf 참고 — 구 aws-eso/
# aws-ingress/aws-api-raw-store/aws-observability-storage 모듈 안에 있던
# 정책 JSON을 재작성 없이 그대로 옮겼다(실전에서 확인된 세부 조건을 잃지
# 않기 위해 — thanos/cloudnativepg 사고 이력, 아래 irsa.tf 주석 참고).

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project     = var.project_name
      owner       = var.owner
      environment = var.environment
      managed_by  = "terraform"
      component   = "2-cluster"
    }
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "seoul/rebuild/1-network/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

data "terraform_remote_state" "persistent" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "seoul/persistent/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

module "eks" {
  source = "../../../modules/aws-eks"

  project_name       = var.project_name
  environment        = var.environment
  cluster_name       = var.cluster_name
  cluster_version    = var.cluster_version
  vpc_id             = data.terraform_remote_state.network.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.network.outputs.private_app_subnet_ids

  endpoint_public_access  = var.endpoint_public_access
  endpoint_private_access = var.endpoint_private_access

  node_instance_types = var.node_instance_types
  node_capacity_type  = var.node_capacity_type
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size

  enable_prefix_delegation = var.enable_prefix_delegation
  max_pods_per_node        = var.max_pods_per_node
  enable_ebs_csi           = var.enable_ebs_csi

  team_members      = var.team_members
  access_policy_arn = var.access_policy_arn
}

# Redis 보안그룹이 EKS 클러스터 보안그룹을 직접 참조한다 — 예전엔 서로 다른
# state라 remote_state로 건너가야 했지만(data 컴포넌트 ← eks 컴포넌트), 이제
# 같은 state 안의 module output이라 더 단순해졌다.
module "data" {
  source = "../../../modules/aws-data"

  project_name = var.project_name
  environment  = var.environment

  vpc_id                    = data.terraform_remote_state.network.outputs.vpc_id
  private_data_subnet_ids   = data.terraform_remote_state.network.outputs.private_data_subnet_ids
  allowed_security_group_id = module.eks.cluster_security_group_id

  redis_node_type                  = var.redis_node_type
  redis_automatic_failover_enabled = var.redis_automatic_failover_enabled
}
