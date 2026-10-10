# 도쿄 persistent — 클러스터 유무와 무관하게 상시 운영(D4, 2026-10-10 확정).
# S3 버킷 2개(복제 대상)와 ACM 인증서만 존재한다. ECR은 없음 — 서울
# registry의 Cross-Region Replication이 AWS 쪽에서 자동으로 리포지토리를
# 복제해주므로, 도쿄 쪽에 Terraform이 관리할 ECR 리소스 자체가 없다
# (경로 구조 개편안 4.1 — "registry는 전달용 output만 있었다"를 실제
# state 조회로 확인, 2026-10-10 회신 문서 5절).

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
      component   = "persistent"
    }
  }
}

module "storage" {
  source = "../../modules/aws-storage"

  project_name = var.project_name
  environment  = var.environment

  buckets = {
    observability = {
      name_suffix       = "observability"
      enable_versioning = true # 복제 대상이 되려면 버저닝 필수(AWS 요구사항)
    }
    api_raw_store = {
      name_suffix       = "raw-store"
      enable_versioning = true
    }
  }

  tags = var.tags
}

module "dns" {
  source = "../../modules/aws-dns"

  project_name = var.project_name
  environment  = var.environment
  domain_name  = var.domain_name

  create_certificate      = true
  enable_failover_routing = false # 레코드는 4-edge 컴포넌트가 담당
}
