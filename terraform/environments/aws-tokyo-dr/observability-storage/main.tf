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

# 서울 observability-storage는 이 컴포넌트보다 먼저 apply돼 있어야 한다 —
# 도쿄 CNPG Replica Cluster(방식 B, manifests/cloudnativepg-cluster/
# object-store-seoul-source.yaml)가 서울 버킷을 읽으려면 cloudnativepg IRSA
# 역할에 그 버킷 읽기 권한이 필요하기 때문(DR 회의 2026-09-30 안건 7 연장선,
# 작업 목록 15번).
data "terraform_remote_state" "seoul_observability_storage" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "${var.seoul_environment}/${var.seoul_region}/observability-storage/terraform.tfstate"
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
  # 리소스 이름과 똑같은 이름의 서비스어카운트를 자동 생성해 쓴다 — 서울
  # 쪽 실제 페일오버 테스트(2026-09-28)에서 이 불일치로 WAL 아카이빙이
  # AccessDenied로 실패하던 것을 발견해 고쳤다. 도쿄는 아직 CNPG를 배포한
  # 적이 없지만, 같은 매니페스트(manifests/cloudnativepg-cluster)를 그대로
  # 재사용할 것이므로 미리 반영해둔다.
  cloudnativepg_service_account_name = "aquasentinel-pg"

  enable_cross_region_read     = true
  cross_region_read_bucket_arn = data.terraform_remote_state.seoul_observability_storage.outputs.bucket_arn
  cross_region_read_prefix     = data.terraform_remote_state.seoul_observability_storage.outputs.cloudnativepg_prefix
}
