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
  failover_hostnames      = ["", "auth", "grafana"]
  failover_role           = "SECONDARY"
  enable_health_check     = false
  cluster_name            = data.terraform_remote_state.cluster.outputs.cluster_name

  # 🔴 DR 훈련 전용(2026-10-27) — 서울과 **같은 호스트 이름**을 SECONDARY 로
  # 등록한다. 서울 쪽 드릴 헬스체크가 뒤집히면 이 레코드가 응답한다.
  #
  # 스위치 변수를 받지 않는 이유 — enable_health_check = false 라 도쿄에는
  # 드릴 헬스체크가 아예 만들어지지 않는다(modules/aws-dns 의 count 조건).
  # 뒤집는 쪽은 언제나 서울 PRIMARY 다.
  drill_hostnames = ["dr-drill"]
}

# ---------------------------------------------------------------------------
# ALB 미발견 시 apply 실패 (2026-10-20 리전 대조 — 서울 4-edge/alarms.tf 와 동일)
#
# 알람·Route53 헬스체크는 서울에만 둔다 — 도쿄는 SECONDARY 이고
# enable_health_check = false 다. 주 리전을 감시하는 게 설계이므로 그 차이는
# 의도된 것이고, 이 가드만 리전과 무관하게 필요하다.
# ---------------------------------------------------------------------------
resource "terraform_data" "require_alb" {
  lifecycle {
    precondition {
      condition     = !var.require_alb || module.dns.alb_dns_name != null
      error_message = "Gateway ALB를 찾지 못했다 — 3-gitops 적용과 ALB 생성을 먼저 확인. 의도한 것이면 -var require_alb=false."
    }
  }
}
