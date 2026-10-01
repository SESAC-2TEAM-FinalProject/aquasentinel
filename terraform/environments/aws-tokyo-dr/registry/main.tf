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
      component   = "registry"
    }
  }
}

# DR 회의(2026-09-30) 안건 5 — A안(Cross-Region Replication) 확정. ECR 복제는
# 원본과 "정확히 같은 이름"으로 대상 리전에 레포를 자동 생성한다 — 그래서 여기서
# 독자적인 이름(aquasentinel-dr-tokyo/*)으로 레포를 또 만들면, 실제 복제된
# 이미지(aquasentinel-dev/*)와 이름이 어긋나 아무도 안 쓰는 빈 레포가 된다.
# 그래서 이 컴포넌트는 더 이상 aws-registry 모듈을 호출하지 않고, 서울이
# 복제해 넣어줄 레포의 URL을 그대로 이 리전 엔드포인트로 조합해서 출력만 한다.
data "terraform_remote_state" "seoul_registry" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "${var.source_environment}/${var.source_region}/registry/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}
