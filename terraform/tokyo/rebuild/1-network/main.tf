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
      component   = "1-network"
    }
  }

  # 서울 1-network와 같은 이유로 둔다(그쪽 주석이 본문) — 2-cluster가
  # aws_ec2_tag로 붙이는 karpenter.sh/discovery를 이 컴포넌트가 드리프트로
  # 보고 지우는 것을 막는다.
  #
  # 2026-10-20 현재 도쿄에는 카펜터가 없어 **이 설정은 무효과다.** 그래도
  # 지금 넣는 이유는 두 가지다. ① 도쿄 카펜터 도입이 예정돼 있고, 그때
  # 서울과 똑같은 함정(apply 한 번에 노드가 안 뜸)을 다시 밟게 된다.
  # ② 리전 간 설정 드리프트를 만들지 않는다(2026-10-20 전수 대조 기준).
  ignore_tags {
    keys = ["karpenter.sh/discovery"]
  }
}

module "network" {
  source = "../../../modules/aws-network"

  project_name       = var.project_name
  environment        = var.environment
  region             = var.region
  availability_zones = var.availability_zones
  single_nat_gateway = var.single_nat_gateway
  eks_cluster_name   = var.eks_cluster_name
}
