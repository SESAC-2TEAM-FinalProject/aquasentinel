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

  project_name        = var.project_name
  gitlab_project_id   = var.gitlab_project_id
  tfstate_bucket_name = var.tfstate_bucket_name

  # 3-gitops plan 이 읽는 gitops 접근 토큰 — plan 역할에 이 비밀만 읽기 허용(서울 dev · 도쿄 dr-tokyo)
  plan_readable_secret_names = ["aquasentinel-dev-argocd-gitops-token", "aquasentinel-dr-tokyo-argocd-gitops-token"]

  build_projects = {
    web = {
      gitlab_project_id = var.web_gitlab_project_id

      # web-backend 는 2026-10-28 에 추가 — 쿠버네티스 객체 이름이 10-26 에
      # status-svc -> web-backend 로 바뀌었는데 ECR 리포지토리 이름만 옛
      # 이름이었다(modules/aws-registry/variables.tf 참고).
      #
      # 🔴 두 리포지토리를 당분간 같이 둔다. 웹 CI 가 같은 태그를 양쪽에 올리는
      # 구간이 있어야 gitops image 를 바꿀 때 되돌릴 길이 남는다. 여기서
      # status-svc 를 먼저 빼면 그 순간 웹 CI push 가 AccessDenied 로 막힌다.
      ecr_repositories = [
        "aquasentinel-dev/status-svc",
        "aquasentinel-dev/web-backend",
        "aquasentinel-dev/web-frontend",
      ]
    }
    api_module = {
      gitlab_project_id = var.api_module_gitlab_project_id
      ecr_repositories = [
        "aquasentinel-dev/api-module/collector",
        "aquasentinel-dev/api-module/processor",
        "aquasentinel-dev/api-module/interpolation",
        "aquasentinel-dev/api-module/grading",
        "aquasentinel-dev/api-module/evaluation",
      ]
    }
  }
}
