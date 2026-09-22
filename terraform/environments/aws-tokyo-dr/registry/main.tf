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
      component   = "registry"
    }
  }
}

# 참고: 서울 ECR과 완전히 별개의 리포지토리다. 리전 간 이미지 복제(ECR replication
# configuration)는 아직 구성하지 않았다 — 6주차 도쿄 페일오버 설계 시 필요 여부를
# 다시 판단한다 (서울에서 push된 이미지를 그대로 쓸지, 복제를 켤지).
module "registry" {
  source = "../../../modules/aws-registry"

  project_name = var.project_name
  environment  = var.environment
}
