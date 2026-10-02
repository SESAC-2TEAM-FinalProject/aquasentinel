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

  # Route53 헬스체크 + Failover 레코드(안건 4, DR 회의 2026-09-30) — 서울=PRIMARY
  # apex(대시보드) + auth(Keycloak, 인증 B안) 둘 다 같은 ALB로 failover
  #
  # 2단계 적용 완료(2026-10-02) — 서울 재기동 후 ALB가 실제로 떠 있는 걸
  # 확인한 뒤 true로 복원. 1단계(TEMP-BOOTSTRAP)에서 순환 의존 때문에
  # false로 뒀던 걸 되돌리는 것.
  enable_failover_routing = true
  failover_hostnames      = ["", "auth"]
  failover_role           = "PRIMARY"
  enable_health_check     = true
  cluster_name            = data.terraform_remote_state.eks.outputs.cluster_name
}
