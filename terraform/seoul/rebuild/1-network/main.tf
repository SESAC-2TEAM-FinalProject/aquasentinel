# VPC/서브넷/NAT — 컴퓨트 전제 레이어 중 첫 단계. eks_cluster_name을 네트워크
# 모듈까지 내려보내는 이유는 서브넷에 kubernetes.io/cluster/<name>=shared
# 태그를 미리 심어둬야 2-cluster가 아직 없는 시점에도 LBC/오토스케일러가
# 쓸 서브넷 디스커버리가 가능하기 때문(순서상 2-cluster보다 먼저 떠야 함).
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # bucket/key/region은 backend.hcl (git 미추적, backend.hcl.example 참고)로 주입한다.
  # 잠금은 Terraform 1.10+ S3 네이티브 락 기능을 쓴다.
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
      component   = "1-network"
    }
  }

  # karpenter.sh/discovery는 2-cluster가 aws_ec2_tag로 붙인다(그쪽 karpenter.tf
  # 주석 — "네트워크 state를 건드리지 않으려고" 택한 방식). 그런데 aws_subnet의
  # tags는 선언한 집합 전체를 관리하므로, 소유자가 다른 그 태그가 이쪽에서는
  # "지워야 할 드리프트"로 보인다. 즉 2-cluster를 적용한 뒤 이 컴포넌트를 그냥
  # apply하면 태그가 지워지고, Karpenter의 subnetSelectorTerms가 서브넷을 찾지
  # 못해 새 노드를 못 띄운다.
  #
  # 실측(2026-10-20): 시험 구역 1 재구축 측정 SIM-08a-R2 확인 항목 ⑪에서
  # 발견(창영님) → 운영 plan에서도 동일 재현. private_app[0~2] 세 개가 모두
  # `"karpenter.sh/discovery" = "aquasentinel-dev-apne2-eks" -> null`.
  #
  # ignore_tags는 aws_ec2_tag 같은 개별 태그 리소스에는 영향을 주지 않으므로
  # (공급자 문서 명시), 2-cluster가 태그를 붙이는 동작은 그대로 유지된다.
  # lifecycle.ignore_changes 대신 이쪽을 쓴 이유 — 공급자가 "태그를 외부에서
  # 관리하는 경우"를 위해 둔 자리이고, 공유 모듈(modules/aws-network)에
  # 카펜터 전용 예외를 심지 않아도 된다.
  ignore_tags {
    keys = ["karpenter.sh/discovery"]
  }
}

module "network" {
  source = "../../../modules/aws-network"

  project_name              = var.project_name
  environment               = var.environment
  region                    = var.region
  availability_zones        = var.availability_zones
  public_subnet_cidrs       = var.public_subnet_cidrs
  private_app_subnet_cidrs  = var.private_app_subnet_cidrs
  private_data_subnet_cidrs = var.private_data_subnet_cidrs
  single_nat_gateway        = var.single_nat_gateway
  eks_cluster_name          = var.eks_cluster_name
}
