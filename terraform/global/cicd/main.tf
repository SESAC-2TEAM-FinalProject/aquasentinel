terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
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
      project    = var.project_name
      owner      = var.owner
      managed_by = "terraform"
      component  = "cicd"
    }
  }
}

# GitLab.com을 직접 신뢰하는 OIDC라(2026-10-09, EKS-IRSA 전제에서 전환 —
# modules/aws-cicd/main.tf 주석 참고) EKS state를 읽을 필요가 없다. 이 컴포넌트
# 자체가 "CI가 쓸 IAM Role을 만드는" 닭과 달걀 컴포넌트라 bootstrap/과 같은
# 이유로 CI 파이프라인 대상에서 제외하고 최초 1회 수동으로 적용한다.
module "cicd" {
  source = "../../modules/aws-cicd"

  project_name      = var.project_name
  gitlab_project_id = var.gitlab_project_id
}
