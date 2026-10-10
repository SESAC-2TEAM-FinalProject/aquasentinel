# 서울 persistent — ECR(registry)·S3 버킷(raw-store/observability/loki)·
# ACM 인증서. 재구축해도 지우지 않는다(D1, prevent_destroy는 aws-storage
# 모듈이 고정값으로 건다). 도쿄가 상시 운영(D4)이라 더 이상 TEMP-BOOTSTRAP
# 토글(enable_tokyo_dr 등)이 필요 없다 — 도쿄 persistent가 항상 존재한다는
# 전제로 복제를 무조건 켠다.

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

locals {
  # thanos/cloudnativepg가 같은 observability 버킷을 prefix로 나눠 공유한다 —
  # 2-cluster의 IRSA 정책이 이 prefix로 접근 범위를 좁히므로 여기서 output해
  # 단일 소스로 둔다(aws-observability-storage 모듈 시절 local.workloads[*].prefix와 동일한 값).
  thanos_prefix        = "thanos/"
  cloudnativepg_prefix = "cloudnativepg/"
}

data "terraform_remote_state" "tokyo_persistent" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "tokyo/persistent/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

module "storage" {
  source = "../../modules/aws-storage"

  project_name = var.project_name
  environment  = var.environment

  buckets = {
    observability = {
      name_suffix                        = "observability"
      enable_versioning                  = true
      noncurrent_version_expiration_days = var.noncurrent_version_expiration_days
      expiration_rules = [
        {
          id     = "thanos-expiration"
          prefix = local.thanos_prefix
          days   = var.thanos_retention_days
        }
        # cloudnativepg/ prefix는 의도적으로 제외 — Barman Cloud가 자기
        # retention-policy로 WAL/베이스 백업을 관리하므로, S3가 별도로
        # 만료시키면 Barman 모르게 PITR 복구 가능 구간이 깨질 수 있다.
      ]
      enable_cross_region_replication    = true
      replication_destination_bucket_arn = data.terraform_remote_state.tokyo_persistent.outputs.bucket_arns["observability"]
    }
    api_raw_store = {
      name_suffix                        = "raw-store"
      enable_versioning                  = true
      noncurrent_version_expiration_days = var.noncurrent_version_expiration_days
      # 원문 보관 기간 정책 자체가 아직 팀 결정 사항으로 남아있어(제작계획서
      # 11절, v1.5 12.1절 미결) expiration_rules는 비워둔다.
      enable_cross_region_replication    = true
      replication_destination_bucket_arn = data.terraform_remote_state.tokyo_persistent.outputs.bucket_arns["api_raw_store"]
    }
    # Loki는 공유 버킷+prefix 대신 전용 버킷을 쓴다 — Loki Helm 차트의
    # "버킷+prefix" 지원(use_thanos_objstore/storage_prefix)이 알려진 버그가
    # 있어(grafana/loki#16599, #18784, #16543 등) classic S3 스토리지
    # 설정(버킷 단위만 받음)을 쓴다. 복제 대상이 아니라 버저닝도 필요 없다.
    loki = {
      name_suffix = "loki"
      expiration_rules = [
        { id = "loki-expiration", days = var.loki_retention_days }
      ]
    }
  }

  tags = var.tags
}

module "registry" {
  source = "../../modules/aws-registry"

  project_name = var.project_name
  environment  = var.environment

  enable_cross_region_replication = true
  replication_destination_region  = "ap-northeast-1"
}

module "dns" {
  source = "../../modules/aws-dns"

  project_name = var.project_name
  environment  = var.environment
  domain_name  = var.domain_name

  create_certificate      = true
  enable_failover_routing = false # 레코드는 4-edge 컴포넌트가 담당
}
