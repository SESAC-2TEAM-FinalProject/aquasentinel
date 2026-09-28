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
      component   = "gitops"
    }
  }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # aws-observability-storage 등과 동일하게 "${name_prefix}-*" 네이밍을 따른다 —
  # aws-eso 모듈의 IAM 정책이 이 접두사로 접근 범위를 좁혀놓았다.
  gitops_pat_secret_name = "${local.name_prefix}-argocd-gitops-token"
  gitops_repo_url        = "https://github.com/SESAC-2TEAM-FinalProject/aquasentinel-gitops.git"
}

data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "${var.environment}/${var.region}/eks/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

data "aws_eks_cluster_auth" "this" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.eks.outputs.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes = {
    host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.eks.outputs.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

data "aws_secretsmanager_secret_version" "gitops_pat" {
  secret_id = local.gitops_pat_secret_name
}

module "eso" {
  source = "../../../modules/aws-eso"

  project_name      = var.project_name
  environment       = var.environment
  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider_url = data.terraform_remote_state.eks.outputs.oidc_provider_url
}

# ---------------------------------------------------------------------------
# Terraform이 직접 설치하는 유일한 Helm 차트. 이후 모든 워크로드(ESO 포함)는
# 이 Argo CD가 aquasentinel-gitops 레포를 보고 스스로 동기화한다.
# ---------------------------------------------------------------------------
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.9.2"
  namespace        = "argocd"
  create_namespace = true
}

# Argo CD가 private 레포를 clone할 때 쓰는 자격증명.
# ESO를 거치지 않고 Terraform이 직접 심는다 — ESO 자신도 이 레포의 Application으로
# 배포되므로, ESO를 거치면 "ESO가 뜨기 전엔 ESO를 못 가져온다"는 순환 의존이 생긴다.
resource "kubernetes_secret_v1" "gitops_repo_creds" {
  metadata {
    name      = "aquasentinel-gitops-repo-creds"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    url      = local.gitops_repo_url
    username = "x-access-token"
    password = data.aws_secretsmanager_secret_version.gitops_pat.secret_string
  }

  type = "Opaque"

  depends_on = [helm_release.argocd]
}

# aquasentinel-gitops의 bootstrap/root-app.yaml과 내용이 동일해야 한다(수동 동기화).
resource "kubernetes_manifest" "root_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = "argocd"
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"

      source = {
        repoURL        = local.gitops_repo_url
        targetRevision = "main"
        path           = "apps"
        directory = {
          recurse = true
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
        ]
      }
    }
  }

  depends_on = [helm_release.argocd]
}
