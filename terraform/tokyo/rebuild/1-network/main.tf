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
