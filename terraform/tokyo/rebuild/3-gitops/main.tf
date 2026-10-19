# gitops 컴포넌트는 서울과 동일하게 세 파일로 나뉜다(main.tf/bootstrap.tf/
# applications.tf, seoul/rebuild/3-gitops/main.tf 주석 참고). 도쿄 고유 차이는
# applications.tf의 patched_apps 내용(실제 패치 값을 채움)과, bootstrap.tf에
# GitLab Runner SA가 없다는 점뿐 — 나머지 배관은 서울과 동일 패턴(remote_state
# 대상만 tokyo/* 경로로 바뀜).

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
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
      component   = "3-gitops"
    }
  }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Application 동기화 재시도 — Argo CD 는 automated sync 가 실패하면 **같은
  # 리비전을 다시 시도하지 않는다**(retry 를 안 적으면). 새 클러스터 부트스트랩에서
  # "아직 없는 CRD"를 쓰는 앱이 먼저 동기화되면 Failed 에서 멈추고 사람이 손으로
  # 다시 동기화해야 한다 — 시험 구역 1에서 13회를 손으로 돌렸다(SIM-08a, 2026-10-19).
  # **도쿄는 지운 상태에서 재구축하는 경로라 이쪽이 실제로 더 자주 탄다.**
  #
  # 값은 gitops `apps/alerting/application.yaml` 이 이미 쓰던 것을 집 표준으로
  # 올린 것이다(누적 약 65분). 서울 main.tf 와 같은 값을 유지한다.
  app_sync_retry = {
    limit = 10
    backoff = {
      duration    = "30s"
      factor      = 2
      maxDuration = "10m"
    }
  }

  gitops_pat_secret_name = "${local.name_prefix}-argocd-gitops-token"
  gitops_repo_url        = "https://gitlab.com/sesac-2team-finalproject/aquasentinel-gitops.git" # GitHub→GitLab 전환(2026-10-11)
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

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "tokyo/rebuild/1-network/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

data "aws_eks_cluster_auth" "this" {
  name = data.terraform_remote_state.cluster.outputs.cluster_name
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.cluster.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.cluster.outputs.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes = {
    host                   = data.terraform_remote_state.cluster.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.cluster.outputs.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
