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
}
