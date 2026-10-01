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
      component   = "dns"
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

module "dns" {
  source = "../../../modules/aws-dns"

  project_name = var.project_name
  environment  = var.environment
  domain_name  = var.domain_name

  # Route53 헬스체크 + Failover 레코드(안건 4, DR 회의 2026-09-30) — 도쿄=SECONDARY
  # (헬스체크 없이 PRIMARY 장애 시에만 응답). apex/auth 호스트 목록은 서울과
  # 반드시 동일해야 한다(같은 (name,type) 쌍에 PRIMARY/SECONDARY 짝이 맞아야 함).
  enable_failover_routing = true
  failover_hostnames      = ["", "auth"]
  failover_role           = "SECONDARY"
  enable_health_check     = false
  cluster_name            = data.terraform_remote_state.eks.outputs.cluster_name
}
