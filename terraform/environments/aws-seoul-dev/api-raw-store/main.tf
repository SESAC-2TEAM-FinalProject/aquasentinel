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
      component   = "api-raw-store"
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

# 도쿄 api-raw-store는 이 컴포넌트보다 먼저 apply돼 있어야 한다 — 복제 설정이
# 도쿄 버킷 ARN을 참조하기 때문(DR 회의 2026-09-30 안건 7, A안).
#
# count = 0 # TEMP-BOOTSTRAP: 도쿄 재구축 후 1로 복원 — 도쿄를 통째로
# 삭제한 상태(2026-10-01)라 이 remote_state를 그냥 두면 서울 plan 자체가
# "no state file" 에러로 깨진다. 도쿄 재구축 후 1로 되돌릴 것.
data "terraform_remote_state" "tokyo_api_raw_store" {
  count   = 0 # TEMP-BOOTSTRAP: 도쿄 재구축 후 1로 복원
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "${var.tokyo_environment}/${var.tokyo_region}/api-raw-store/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

module "api_raw_store" {
  source = "../../../modules/aws-api-raw-store"

  project_name      = var.project_name
  environment       = var.environment
  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider_url = data.terraform_remote_state.eks.outputs.oidc_provider_url

  enable_cross_region_replication    = false # TEMP-BOOTSTRAP: 도쿄 재구축 후 true로 복원
  replication_destination_bucket_arn = one(data.terraform_remote_state.tokyo_api_raw_store[*].outputs.bucket_arn)
}
