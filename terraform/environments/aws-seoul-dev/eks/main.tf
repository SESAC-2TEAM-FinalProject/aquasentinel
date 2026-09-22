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
      component   = "eks"
    }
  }
}

# network 컴포넌트의 state를 읽어 vpc_id / subnet id를 가져온다.
# (component별 state 분리 설계 — 서로 다른 컴포넌트를 서로 다른 팀원이 동시에 apply해도 lock 충돌이 없다)
data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "${var.environment}/${var.region}/network/terraform.tfstate"
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
}
