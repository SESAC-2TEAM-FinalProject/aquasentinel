# EKS + Access Entry + Redis + 전체 워크로드 IRSA — 서울 2-cluster와 동일한
# 이유(D2)로 한 컴포넌트에 합쳤다. 도쿄 고유 차이는 irsa.tf의 cloudnativepg
# 역할에 크로스리전 읽기 권한이 추가된다는 점과 GitLab Runner IRSA가 없다는
# 점뿐(도쿄는 CI가 돌지 않음) — 나머지는 서울과 동일 패턴.

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
      component   = "2-cluster"
    }
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

data "terraform_remote_state" "persistent" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "tokyo/persistent/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

module "eks" {
  source = "../../../modules/aws-eks"

  project_name       = var.project_name
  environment        = var.environment
  cluster_name       = var.cluster_name
  cluster_version    = var.cluster_version
  vpc_id             = data.terraform_remote_state.network.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.network.outputs.private_app_subnet_ids
  # 서울은 컨트롤플레인(private_subnet_ids)과 관리형 노드그룹(node_group_subnet_ids)
  # 서브넷을 분리했지만(2026-10-13, subnet_ids 변경 시 노드그룹 강제 재생성 이슈 —
  # modules/aws-eks 주석 참고), 도쿄는 아직 3 AZ 확장 작업 전이라 분리할 이유가
  # 없다 — 컨트롤플레인과 동일한 서브넷 목록을 그대로 재사용한다. 도쿄도 나중에
  # 3 AZ로 확장하게 되면 서울과 동일하게 분리해야 한다.
  node_group_subnet_ids = data.terraform_remote_state.network.outputs.private_app_subnet_ids

  endpoint_public_access  = var.endpoint_public_access
  endpoint_private_access = var.endpoint_private_access

  node_instance_types = var.node_instance_types
  node_capacity_type  = var.node_capacity_type
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size

  # 스테이트풀 전용 고정 노드그룹 — 서울(seoul/rebuild/2-cluster/main.tf)과 같은
  # 라벨/taint 키·값을 쓴다. 서울 쪽 주석이 이유를 적어 뒀다: 카펜터 stateful
  # NodePool이 쓰던 키를 재사용해서 "워크로드 매니페스트(nodeSelector/tolerations)를
  # 건드릴 필요가 없게" 한 것이다.
  #
  # 🔴 도쿄에만 이 두 블록이 없었다(2026-10-24 구축 전 검토에서 발견). 모듈 기본값이
  # node_labels = {} · node_taints = [] 라서(modules/aws-eks/variables.tf) 도쿄 노드에는
  # 라벨이 아예 붙지 않는데, gitops manifests/ 는 두 리전 공용이고 그 안에 nodeSelector
  # aquasentinel.io/nodepool=stateful 이 걸린 워크로드가 23개다(gitlab/main 전수):
  # Cluster/aquasentinel-pg(DB) · Keycloak 2 · web 4(web-backend(옛 status-svc)·
  # web-frontend·alert-worker·ocean-fetch) · api-module 14 · egress-proxy · redis-exporter.
  # 즉 이게 없으면 apply 는 성공하는데 그 23개가 전부 Pending 으로 남아 빈 클러스터가
  # 된다 — 에러가 나지 않아 더 늦게 발견된다.
  #
  # taint 는 Pending 해소에 필수는 아니다(라벨만 있어도 nodeSelector 는 통과하고,
  # toleration 은 taint 가 없어도 무해하다). 그래도 서울과 같은 구조로 둔다 — 모듈이
  # 애드온 toleration 을 var.node_taints 에서 파생시키므로(modules/aws-eks/main.tf:16~30)
  # 둘을 짝으로 두는 것이 설계 의도다.
  node_labels = {
    "aquasentinel.io/nodepool" = "stateful"
  }
  node_taints = [
    {
      key    = "dedicated"
      value  = "stateful"
      effect = "NO_SCHEDULE"
    }
  ]

  enable_prefix_delegation = var.enable_prefix_delegation
  enable_network_policy    = var.enable_network_policy
  max_pods_per_node        = var.max_pods_per_node
  enable_ebs_csi           = var.enable_ebs_csi

  team_members      = var.team_members
  access_policy_arn = var.access_policy_arn

  # CI Terraform plan 역할 — 3-gitops plan 이 클러스터를 읽을 수 있게(읽기 전용).
  # 역할 자체는 global/cicd 가 만든다(이름 규칙: <project>-gitlab-terraform-plan — 환경 이름 없음, modules/aws-cicd 의 name_prefix = project_name).
  readonly_principal_arns = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-gitlab-terraform-plan",
  ]

  # CI 알람 점검 역할 — Alertmanager 파드 하나에 exec 해 Silence 를 건다(알람 묶음 C).
  # 권한은 gitops manifests/alerting/routing/rbac-maintenance.yaml 의 RBAC 가 정한다(그룹 이름으로 연결).
  # 역할은 global/cicd 가 만든다(이름 규칙은 위 plan 역할과 같다) — global/cicd 적용이 먼저다.
  group_access_entries = {
    alert_maintenance = {
      principal_arn     = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-gitlab-alert-maintenance"
      kubernetes_groups = ["aquasentinel:alert-maintenance"]
    }
  }
}

module "data" {
  source = "../../../modules/aws-data"

  project_name = var.project_name
  environment  = var.environment

  vpc_id                    = data.terraform_remote_state.network.outputs.vpc_id
  private_data_subnet_ids   = data.terraform_remote_state.network.outputs.private_data_subnet_ids
  allowed_security_group_id = module.eks.cluster_security_group_id

  redis_node_type                  = var.redis_node_type
  redis_automatic_failover_enabled = var.redis_automatic_failover_enabled
}

data "aws_caller_identity" "current" {}
