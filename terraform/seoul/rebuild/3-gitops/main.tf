# gitops 컴포넌트는 세 파일로 나뉜다(2026-10-09 최초 분리, 2026-10-10 경로
# 구조 개편으로 remote_state 배선 변경 — 리소스 내용 자체는 바뀌지 않음):
#   - main.tf         배관: terraform/provider 설정, 공용 remote_state
#   - bootstrap.tf     Terraform이 직접 만드는 K8s 리소스(ArgoCD Helm 설치, ServiceAccount 등)
#   - applications.tf  ArgoCD Application 직접 생성(두 번째 GitOps 엔진 역할) — 장기적으로는
#                       apps/ 레포로 옮기는 게 근본 해결책(이미 일부 이전함, Option 3 Step 1)
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

  # aws-storage 등과 동일하게 "${name_prefix}-*" 네이밍을 따른다 —
  # 2-cluster의 ESO IAM 정책이 이 접두사로 접근 범위를 좁혀놓았다.
  gitops_pat_secret_name = "${local.name_prefix}-argocd-gitops-token"
  gitops_repo_url        = "https://github.com/SESAC-2TEAM-FinalProject/aquasentinel-gitops.git"
}

# 2-cluster가 EKS+전체 워크로드 IRSA를 갖고 있다(D2, 경로 구조 개편) —
# 예전엔 eks/observability-storage/api-raw-store/ingress 4개 state를
# 따로 읽었지만, 이제 cluster(2-cluster)와 persistent(버킷·인증서) 둘로
# 줄었다.
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

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "seoul/rebuild/1-network/terraform.tfstate"
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
