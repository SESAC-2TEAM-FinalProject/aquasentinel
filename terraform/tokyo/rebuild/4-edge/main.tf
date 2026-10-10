# Route53 Failover 레코드 — 서울 4-edge와 동일 이유로 분리된 컴포넌트
# (seoul/rebuild/4-edge/main.tf 주석 참고). 도쿄=SECONDARY라 헬스체크 없이
# PRIMARY(서울) 장애 시에만 응답한다. apex/auth 호스트 목록은 서울과 반드시
# 동일해야 한다(같은 (name,type) 쌍에 PRIMARY/SECONDARY 짝이 맞아야 함).

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
      component   = "4-edge"
    }
  }
}

data "terraform_remote_state" "cluster" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "tokyo/rebuild/2-cluster/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

data "terraform_remote_state" "persistent" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "tokyo/persistent/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

module "dns" {
  source = "../../../modules/aws-dns"

  project_name = var.project_name
  environment  = var.environment
  domain_name  = data.terraform_remote_state.persistent.outputs.domain_name

  create_certificate = false

  enable_failover_routing = true
  failover_hostnames      = ["", "auth"]
  failover_role           = "SECONDARY"
  enable_health_check     = false
  cluster_name            = data.terraform_remote_state.cluster.outputs.cluster_name
}
