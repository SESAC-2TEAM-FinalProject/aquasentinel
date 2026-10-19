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

# Route53 헬스체크 지표(AWS/Route53 HealthCheckStatus)는 us-east-1에만 쌓인다.
# 그 알람용 SNS 토픽도 같은 리전에 있어야 CloudWatch 알람이 게시할 수 있다.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

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
  name_prefix          = "${var.project_name}-${var.environment}"
}

data "aws_caller_identity" "current" {}

locals {
  prod_account_id = "379937169195"

  # 시험 구역 계정 목록은 **운영 계정에서 apply 할 때만** 쓴다.
  #
  # 이 컴포넌트는 시험 계정에서도 똑같이 돌아간다. 거르지 않으면 시험 구역 A가
  # 자기 백업 버킷을 시험 구역 B에게 열게 되는데, 그 버킷에는 운영 기준 백업에서
  # 복구한 데이터가 들어 있다(D-17). ECR(pull_only_account_ids)은 자기 레지스트리를
  # 여는 것이라 무해해서 거르지 않지만, 버킷은 교차 노출이 생기므로 거른다.
  testfield_account_ids = (
    data.aws_caller_identity.current.account_id == local.prod_account_id
    ? var.testfield_account_ids
    : []
  )
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

      # 시험 구역(테스트 필드)이 운영 기준 백업에서 DB를 복구한다(D-17).
      # cloudnativepg/ 접두사만 · 읽기만 — 같은 버킷의 Thanos 지표는 열지 않는다.
      # 시험 구역을 닫으면 이 블록을 지운다.
      cross_account_read = length(local.testfield_account_ids) == 0 ? null : {
        account_ids = local.testfield_account_ids
        prefixes    = ["cloudnativepg/*"]
      }
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

  # 시험 구역(테스트 필드) 계정 — 운영 이미지를 받기만 한다(쓰기 권한 없음). 시험 구역을 닫으면 목록에서 뺀다.
  #
  # 백업 버킷(local.testfield_account_ids)과 **같은 목록을 쓴다.** 둘이 갈리면
  # "DB 복구는 되는데 이미지를 못 받는" 상태가 된다 — 시험 구역이 3-gitops 에서
  # ImagePullBackOff 로 멈춘다. 여기는 자기 레지스트리를 여는 것이라 계정 거르기가
  # 필요 없어 변수를 그대로 쓴다(버킷 쪽 주석 참고).
  pull_only_account_ids = var.testfield_account_ids
}

module "dns" {
  source = "../../modules/aws-dns"

  project_name = var.project_name
  environment  = var.environment
  domain_name  = var.domain_name

  create_certificate      = true
  enable_failover_routing = false # 레코드는 4-edge 컴포넌트가 담당
}
