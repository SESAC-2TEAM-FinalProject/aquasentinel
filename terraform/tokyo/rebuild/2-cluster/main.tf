# EKS + Access Entry + Redis + 전체 워크로드 IRSA — 서울 2-cluster와 동일한
# 이유(D2)로 한 컴포넌트에 합쳤다. 도쿄 고유 차이는 irsa.tf의 cloudnativepg
# 역할에 크로스리전 읽기 권한이 추가된다는 점과 GitLab Runner IRSA가 없다는
# 점뿐(도쿄는 CI가 돌지 않음) — 나머지는 서울과 동일 패턴.

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
    key    = "tokyo/rebuild/1-network/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

data "terraform_remote_state" "persistent" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "tokyo/persistent/terraform.tfstate"
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
