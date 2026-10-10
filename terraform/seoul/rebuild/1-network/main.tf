# VPC/서브넷/NAT — 컴퓨트 전제 레이어 중 첫 단계. eks_cluster_name을 네트워크
# 모듈까지 내려보내는 이유는 서브넷에 kubernetes.io/cluster/<name>=shared
# 태그를 미리 심어둬야 2-cluster가 아직 없는 시점에도 LBC/오토스케일러가
# 쓸 서브넷 디스커버리가 가능하기 때문(순서상 2-cluster보다 먼저 떠야 함).
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # bucket/key/region은 backend.hcl (git 미추적, backend.hcl.example 참고)로 주입한다.
  # 잠금은 Terraform 1.10+ S3 네이티브 락 기능을 쓴다.
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
      component   = "1-network"
    }
  }
}

module "network" {
  source = "../../../modules/aws-network"

  project_name       = var.project_name
  environment        = var.environment
  region             = var.region
  availability_zones = var.availability_zones
  single_nat_gateway = var.single_nat_gateway
  eks_cluster_name   = var.eks_cluster_name
}
