# EKS + Access Entry + Redis + 전체 워크로드 IRSA — 전부 "클러스터 수명"에
# 종속되어 재구축 때 같이 사라지는 자원이라 한 컴포넌트로 합쳤다(D2, 경로
# 구조 개편안 2026-10-10). IRSA 정책 내용은 irsa.tf 참고 — 구 aws-eso/
# aws-ingress/aws-api-raw-store/aws-observability-storage 모듈 안에 있던
# 정책 JSON을 재작성 없이 그대로 옮겼다(실전에서 확인된 세부 조건을 잃지
# 않기 위해 — thanos/cloudnativepg 사고 이력, 아래 irsa.tf 주석 참고).

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
    key    = "seoul/rebuild/1-network/terraform.tfstate"
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

module "eks" {
  source = "../../../modules/aws-eks"

  project_name    = var.project_name
  environment     = var.environment
  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  vpc_id          = data.terraform_remote_state.network.outputs.vpc_id
  # EKS 컨트롤플레인은 클러스터 생성 이후 "새로운 AZ"를 추가할 수 없다 — 기존 AZ 안의
  # 서브넷 추가만 허용된다(2026-10-13 실제 apply 시도에서 AWS가 400
  # InvalidParameterException으로 명시 거부: "Provided subnets belong to the AZs
  # 'ap-northeast-2a,ap-northeast-2b,ap-northeast-2c'. But they should belong to the
  # exact set of AZs ... in which subnets were provided during cluster creation.").
  # 그래서 컨트롤플레인용 subnet_ids는 생성 당시 AZ(2a, 2c)로 계속 고정한다. 컨트롤플레인
  # 서브넷과 워커 노드 서브넷이 같은 AZ 집합일 필요는 없으므로(노드는 VPC 라우팅으로
  # 컨트롤플레인과 통신), 2b는 카펜터 EC2NodeClass의 워커 전용 서브넷으로만 쓴다.
  private_subnet_ids = slice(data.terraform_remote_state.network.outputs.private_app_subnet_ids, 0, 2)
  # 2026-10-14 — 스테이트풀 복귀 작업으로 관리형 노드그룹이 다시 3 AZ(2a/2b/2c)
  # 전부를 쓰게 된다. subnet_ids 변경이라 노드그룹이 강제 재생성되는데, 지금 이
  # 노드그룹엔 카펜터 컨트롤러만 있어서(일반/스테이트풀 워크로드 없음) 안전하다
  # (modules/aws-eks 주석 참고 — 예전엔 CNPG/NATS가 떠 있어서 이 변경이 위험했다).
  node_group_subnet_ids = slice(data.terraform_remote_state.network.outputs.private_app_subnet_ids, 0, 3)

  endpoint_public_access  = var.endpoint_public_access
  endpoint_private_access = var.endpoint_private_access

  node_instance_types = var.node_instance_types
  node_capacity_type  = var.node_capacity_type
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size

  # 스테이트풀(CNPG·NATS) 전용 고정 노드그룹 — 카펜터 stateful NodePool이 쓰던
  # 라벨/taint 키·값을 그대로 재사용해서 워크로드 매니페스트(nodeSelector/
  # tolerations)를 건드릴 필요가 없게 했다.
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

  # var.team_members(terraform.tfvars, 커밋 안 됨)는 이미 존재하는 외부 IAM 개체(같은
  # 계정 User, 또는 수동 생성된 크로스어카운트 Role)를 그대로 가리키고, 여기서는 이
  # 컴포넌트가 직접 만드는 크로스어카운트 Role(cross-account-members.tf)을 합류시킨다
  # — ARN을 tfvars에 손으로 또 적으면 두 곳이 어긋날 위험이 생긴다(2026-10-14).
  #
  # 이름이 겹치면 이 컴포넌트가 만드는 Role 쪽을 남긴다. 모듈이 team_members 를
  # name 으로 키를 만들기 때문에(modules/aws-eks/main.tf:393) 같은 이름이 둘이면
  # "Duplicate object key" 로 plan 단계에서 죽는다 — 2026-10-19 시험 구역 1 에서
  # 묶음 tfvars 의 team_members 에 `jaehee` 가 들어 있어 실제로 발생했다.
  # 에러 메시지가 원인을 가리키지 않아 찾기 어려우므로 여기서 걸러 둔다.
  team_members = concat(
    [for m in var.team_members : m if !contains(keys(local.cross_account_members), m.name)],
    [for name, role in aws_iam_role.cross_account_member : { name = name, iam_arn = role.arn }]
  )
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

# Redis 보안그룹이 EKS 클러스터 보안그룹을 직접 참조한다 — 예전엔 서로 다른
# state라 remote_state로 건너가야 했지만(data 컴포넌트 ← eks 컴포넌트), 이제
# 같은 state 안의 module output이라 더 단순해졌다.
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
