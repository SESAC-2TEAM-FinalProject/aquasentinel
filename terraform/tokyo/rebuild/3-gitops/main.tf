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

# 🔴 Stage 2(직접 전송) 전용 — 서울 내부 NLB 주소를 읽기 위한 별칭.
#   읽기만 한다. 이 컴포넌트는 서울에 **아무것도 만들지 않는다**.
#   var.enable_stage2_streaming 이 false 면 이 provider 를 쓰는 data 가
#   count = 0 이라 호출 자체가 없다(1부 경로).
provider "aws" {
  alias  = "seoul"
  region = var.seoul_region
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

  # 평상시 대기 상태인가 — var.dr_mode 설명 참고. 패치를 넣고 빼는 조건으로만 쓴다.
  dr_standby = var.dr_mode == "standby"

  gitops_pat_secret_name = "${local.name_prefix}-argocd-gitops-token"
  gitops_repo_url        = "https://gitlab.com/sesac-2team-finalproject/aquasentinel-gitops.git" # GitHub→GitLab 전환(2026-10-11)

  # 🔴 CI 러너 이미지에는 kubectl 이 없다 (2026-10-25 발견).
  #
  # `.gitlab-ci.yml` 의 terraform 잡은 `hashicorp/terraform:${TF_VERSION}` 로 도는데
  # 그 이미지(알파인 기반)에 kubectl 바이너리가 없다. local-exec 로 kubectl 을 쓰는
  # null_resource 두 개(bootstrap.tf 의 wait_for_api_module_namespace,
  # applications.tf 의 restart_lbc_for_gateway_api)가 전부 여기에 걸린다:
  #
  #     /bin/sh: kubectl: not found
  #     TIMEOUT: api-module namespace not found after 5m
  #
  # 🔴 왜 서울에서는 안 드러났나 — 두 리소스 모두 **2026-10-14 수정 이전**에
  # 생성됐고, 그때는 `rm -f` 가 마지막 줄이라 kubectl 실패가 exit 0 으로 가려져
  # "성공"으로 state 에 기록됐다(그 수정의 주석이 지적한 바로 그 버그). null_resource
  # 는 triggers 가 없으면 재실행되지 않아 이후 apply 에서도 다시 돌지 않았다.
  # **도쿄가 최초 적용이라 처음으로 제대로 실패했다.** 즉 이 두 동작은 지금까지
  # 한 번도 실제로 수행된 적이 없다(서울 LBC 재시작 포함 — 「도쿄 반영 목록」에 기록).
  #
  # 해결은 명령 안에서 kubectl 을 확보하는 것으로 좁힌다. CI 이미지를 바꾸면
  # 서울 apply 경로까지 영향을 받는데, 판정 창(2026-10-22~11-10) 중에는 운영
  # 파이프라인을 건드리지 않는다는 원칙이 있다. 알파인 패키지를 먼저 시도하고,
  # 저장소에 없으면 공식 바이너리를 내려받는다(클러스터가 1.31 이라 같은 마이너).
  ensure_kubectl = <<-EOT
    if ! command -v kubectl >/dev/null 2>&1; then
      apk add --no-cache kubectl >/dev/null 2>&1 \
        || { wget -qO /usr/local/bin/kubectl "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl" \
             && chmod +x /usr/local/bin/kubectl; }
    fi
    command -v kubectl >/dev/null 2>&1 || { echo "kubectl 을 준비하지 못했다" >&2; exit 1; }
  EOT
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
