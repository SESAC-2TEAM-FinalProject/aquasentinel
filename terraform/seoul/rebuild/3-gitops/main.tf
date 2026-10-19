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
  gitops_repo_url        = "https://gitlab.com/sesac-2team-finalproject/aquasentinel-gitops.git" # GitHub→GitLab 전환(2026-10-11)

  # Application 동기화 재시도 — Argo CD 는 automated sync 가 실패하면 **같은
  # 리비전을 다시 시도하지 않는다**(retry 를 안 적으면). 그래서 새 클러스터
  # 부트스트랩에서 "아직 없는 CRD"를 쓰는 앱이 먼저 동기화되면 Failed 에서 멈추고
  # 사람이 손으로 다시 동기화해야 한다 — 시험 구역 1에서 시크릿 계열 4개 앱과
  # karpenter 를 합쳐 **13회를 손으로** 돌렸다(SIM-08a, 2026-10-19).
  #
  # 값은 gitops `apps/alerting/application.yaml` 이 이미 쓰고 있던 것을 그대로
  # 집 표준으로 올린 것이다(누적 약 65분). 재구축 수렴에는 충분하고, 정말 깨진
  # 앱은 10회 뒤 Failed 로 드러나 조용히 묻히지 않는다. root.tf 의 kustomize
  # 패치가 이 값을 apps/ 의 Application 전체에도 얹는다.
  app_sync_retry = {
    limit = 10
    backoff = {
      duration    = "30s"
      factor      = 2
      maxDuration = "10m"
    }
  }
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
