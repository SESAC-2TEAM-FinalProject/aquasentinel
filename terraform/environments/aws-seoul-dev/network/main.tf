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
      component   = "network"
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
