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

# DR 회의(2026-09-30) 안건 5 — A안(Cross-Region Replication) 확정. 서울이
# 소스 리전이라 여기서만 켠다 — 도쿄 쪽 registry 모듈 호출은 이 값을 false로
# 둬야 한다(계정 전체 싱글톤 리소스, 양쪽에서 켜면 충돌).
module "registry" {
  source = "../../../modules/aws-registry"

  project_name = var.project_name
  environment  = var.environment

  enable_cross_region_replication = true
  replication_destination_region  = "ap-northeast-1"
}
