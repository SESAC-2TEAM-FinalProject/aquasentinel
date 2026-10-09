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
      component   = "observability-storage"
    }
  }
}

data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "${var.environment}/${var.region}/eks/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

# 도쿄 observability-storage는 이 컴포넌트보다 먼저 apply돼 있어야 한다 —
# 복제 설정이 도쿄 버킷 ARN을 참조하기 때문(DR 회의 2026-09-30 안건 7, A안).
#
# count = 0 # TEMP-BOOTSTRAP: 도쿄 재구축 후 1로 복원 — 도쿄를 통째로
# 삭제한 상태(2026-10-01)라 이 remote_state를 그냥 두면 서울 plan 자체가
# "no state file" 에러로 깨진다. 도쿄 재구축 후 1로 되돌릴 것.
data "terraform_remote_state" "tokyo_observability_storage" {
  count   = 0 # TEMP-BOOTSTRAP: 도쿄 재구축 후 1로 복원
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "${var.tokyo_environment}/${var.tokyo_region}/observability-storage/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

module "observability_storage" {
  source = "../../../modules/aws-observability-storage"

  project_name      = var.project_name
  environment       = var.environment
  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider_url = data.terraform_remote_state.eks.outputs.oidc_provider_url

  # cnpg-system은 오퍼레이터 전용 네임스페이스라, 실제 DB Cluster는 분리한다.
  cloudnativepg_namespace = "aquasentinel-db"

  # CNPG는 serviceAccountTemplate으로 이름을 새로 짓지 못하고, Cluster
  # 리소스 이름(aquasentinel-pg, manifests/cloudnativepg-cluster/cluster.yaml)과
  # 똑같은 이름의 서비스어카운트를 자동 생성해 쓴다 — 기본값
  # "cloudnativepg-backup"과 실제로 달라서, 실제 페일오버 테스트 중
  # WAL 아카이빙이 "sts:AssumeRoleWithWebIdentity" AccessDenied로 계속
  # 실패하고 있었음을 뒤늦게 발견했다(트러스트 정책의 sub 조건 불일치).
  cloudnativepg_service_account_name = "aquasentinel-pg"

  # 모듈 기본값 "thanos"는 실제와 다르다 — kube-prometheus-stack 차트가 자동
  # 생성하는 Prometheus ServiceAccount 이름 그대로 써야 한다(cloudnativepg와
  # 같은 이유로 트러스트 정책 sub 불일치, 2026-10-08 thanos-sidecar S3
  # Access Denied로 실제 확인).
  thanos_service_account_name = "kube-prometheus-stack-prometheus"

  enable_cross_region_replication    = false # TEMP-BOOTSTRAP: 도쿄 재구축 후 true로 복원
  replication_destination_bucket_arn = one(data.terraform_remote_state.tokyo_observability_storage[*].outputs.bucket_arn)
}
