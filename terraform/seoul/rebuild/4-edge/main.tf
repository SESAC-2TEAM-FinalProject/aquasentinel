# Route53 Failover 레코드 + 헬스체크 — gitops(ALB 생성) 뒤에만 의미가
# 있어서 별도 컴포넌트로 분리했다(경로 구조 개편, S5). 인증서는 persistent에
# 있고 여기서는 레코드만 다룬다 — 예전엔 인증서와 레코드가 한 컴포넌트에
# 같이 있어서 레코드가 gitops 뒤에야 가능한 ALB 조회에 의존하는 바람에
# 인증서까지 2단계 적용(TEMP-BOOTSTRAP)이 필요했는데, 이 분리로 그 문제
# 자체가 사라진다.

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
    key    = "seoul/rebuild/2-cluster/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

data "terraform_remote_state" "persistent" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "seoul/persistent/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

module "dns" {
  source = "../../../modules/aws-dns"

  project_name = var.project_name
  environment  = var.environment
  domain_name  = data.terraform_remote_state.persistent.outputs.domain_name

  create_certificate = false

  # Route53 헬스체크 + Failover 레코드 — 서울=PRIMARY. apex(대시보드) +
  # auth(Keycloak, 인증 B안) 둘 다 같은 ALB로 failover. 도쿄
  # tokyo/rebuild/4-edge(SECONDARY)가 아직 적용 안 된 상태에서 이 헬스체크가
  # 실패하면 failover할 대상 자체가 없어 그냥 장애로 끝난다 — 이 레코드
  # 하나만으로는 DR이 완성되지 않는다.
  enable_failover_routing = true
  failover_hostnames      = ["", "auth"]
  failover_role           = "PRIMARY"
  enable_health_check     = true
  cluster_name            = data.terraform_remote_state.cluster.outputs.cluster_name
}
