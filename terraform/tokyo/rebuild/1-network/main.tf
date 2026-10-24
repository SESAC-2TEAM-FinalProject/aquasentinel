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

  project_name = var.project_name
  environment  = var.environment
  region       = var.region

  # 3 AZ + 도쿄 전용 CIDR(10.1.0.0/16) — 2026-10-25. 모듈 기본값은 AZ 2개 ·
  # 10.0.x 전제라 네 개를 다 넘겨야 한다(variables.tf 주석 참고). 서울
  # 1-network/main.tf 와 같은 형태이고, 값만 10.1 대역이다.
  availability_zones        = var.availability_zones
  vpc_cidr                  = var.vpc_cidr
  public_subnet_cidrs       = var.public_subnet_cidrs
  private_app_subnet_cidrs  = var.private_app_subnet_cidrs
  private_data_subnet_cidrs = var.private_data_subnet_cidrs

  single_nat_gateway = var.single_nat_gateway
  eks_cluster_name   = var.eks_cluster_name
}
