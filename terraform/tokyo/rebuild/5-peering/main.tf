# Stage 2 — 서울·도쿄 VPC 피어링 (2026-10-27)
#
# 왜 별도 컴포넌트인가
#   Stage 0(백업 후 복구)에는 피어링이 필요 없다. 1부 훈련은 1~4 만 돌리고
#   이 컴포넌트는 **존재하지도 않는다**. Stage 2(직접 전송)에서만 쓴다.
#   수명이 다른 것을 1-network 에 섞으면 ⑴ 2부 준비 때 VPC·서브넷·NAT 가
#   전부 plan 에 떠서 drift 가 같이 딸려오고 ⑵ 훈련 중 피어링만 떼려면
#   네트워크 전체를 다시 apply 해야 한다.
#
#   그리고 뒷정리가 줄어든다 — 계획서 6.3 의 #2(피어링)·#3(라우트)이
#   `terraform destroy` **한 번**으로 끝난다. 훈련을 두 번 도는데 사람이
#   기억해야 할 항목이 적을수록 좋다.
#
# 무엇이 여기 없는가 🔴
#   **서울 내부 NLB 와 도쿄 CIDR 허용 규칙은 여기 없다.** 둘 다 gitops 쪽
#   Service 하나로 끝난다 —
#     manifests/cloudnativepg/cluster/pg-rw-internal-nlb.yaml
#   LBC v3.5.0 이 NLB 보안그룹을 지원하므로 `loadBalancerSourceRanges` 에
#   도쿄 CIDR 을 적으면 LBC 가 NLB 앞단 SG 를 만들어 준다. 백엔드(노드 SG)
#   규칙도 LBC 가 자동으로 넣는다 — 서울 클러스터 SG 에 이미 ALB 용으로
#   `elbv2.k8s.aws/targetGroupBinding=shared` 규칙이 그렇게 들어가 있다(실측).
#   Terraform 으로 SG 규칙을 따로 쓰면 LBC 가 관리하는 것과 겹친다.
#
# 적용 전제 🔴
#   도쿄 `1-network` 가 **이미 서 있어야 한다.** 피어링은 양쪽 VPC 가
#   존재해야 만들 수 있다. 1부 2단계(또는 2부 0단계)에서 도쿄를 세운 뒤에
#   이것을 돌린다. 도쿄를 destroy 하면 피어링도 같이 사라지므로, 도쿄를
#   다시 세울 때마다 이 컴포넌트도 다시 apply 해야 한다.

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

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    project     = var.project_name
    owner       = var.owner
    environment = var.environment
    managed_by  = "terraform"
    component   = "5-peering"
  }
}

# 요청하는 쪽 — 도쿄
provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

# 🔴 수락하는 쪽 — 서울.
#   리전 간 피어링은 `auto_accept` 를 쓸 수 없다. 반드시 상대 리전에서
#   수락 리소스를 따로 만들어야 하고, 그래서 provider 가 둘 필요하다.
provider "aws" {
  alias  = "seoul"
  region = var.seoul_region

  default_tags {
    tags = local.common_tags
  }
}

data "terraform_remote_state" "tokyo_network" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "tokyo/rebuild/1-network/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

data "terraform_remote_state" "seoul_network" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "seoul/rebuild/1-network/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

locals {
  tokyo_vpc_id   = data.terraform_remote_state.tokyo_network.outputs.vpc_id
  tokyo_vpc_cidr = data.terraform_remote_state.tokyo_network.outputs.vpc_cidr
  seoul_vpc_id   = data.terraform_remote_state.seoul_network.outputs.vpc_id
  seoul_vpc_cidr = data.terraform_remote_state.seoul_network.outputs.vpc_cidr
}

# ─────────────────────────────────────────────────────────────────────────
# 1. 피어링 — 요청(도쿄) → 수락(서울)
# ─────────────────────────────────────────────────────────────────────────

resource "aws_vpc_peering_connection" "to_seoul" {
  vpc_id      = local.tokyo_vpc_id
  peer_vpc_id = local.seoul_vpc_id
  peer_region = var.seoul_region

  # 🔴 리전 간에는 true 를 줄 수 없다. 아래 accepter 가 수락한다.
  auto_accept = false

  tags = {
    Name = "${local.name_prefix}-to-seoul"
    Role = "dr-stage2"
  }

  lifecycle {
    precondition {
      # 두 대역이 겹치면 피어링 자체가 성립하지 않는다. 도쿄를 10.1.0.0/16
      # 으로 잡아 둔 이유가 이것이고(1-network/variables.tf), 누가 되돌리면
      # 여기서 먼저 잡는다.
      condition     = local.tokyo_vpc_cidr != local.seoul_vpc_cidr
      error_message = "서울(${local.seoul_vpc_cidr})과 도쿄(${local.tokyo_vpc_cidr}) CIDR 이 같다 — 피어링 불가. 도쿄 1-network 의 vpc_cidr 을 확인하라."
    }
  }
}

resource "aws_vpc_peering_connection_accepter" "seoul" {
  provider = aws.seoul

  vpc_peering_connection_id = aws_vpc_peering_connection.to_seoul.id
  auto_accept               = true

  tags = {
    Name = "${local.name_prefix}-from-tokyo"
    Role = "dr-stage2"
  }
}

# ─────────────────────────────────────────────────────────────────────────
# 2. 라우트 — 양쪽 private 라우트 테이블에 상대 대역을 넣는다
#
#   라우트 테이블 ID 는 1-network outputs 에 없어서 이름으로 찾는다.
#   aws-network 모듈이 "${name_prefix}-private-rt-N" 으로 짓고, N 은
#   single_nat_gateway 설정에 따라 1개일 수도 AZ 수만큼일 수도 있다.
#   그래서 복수형 data source 로 전부 받아 for_each 로 돈다.
# ─────────────────────────────────────────────────────────────────────────

data "aws_route_tables" "tokyo_private" {
  vpc_id = local.tokyo_vpc_id

  filter {
    name   = "tag:Name"
    values = ["${local.name_prefix}-private-rt-*"]
  }
}

data "aws_route_tables" "seoul_private" {
  provider = aws.seoul

  vpc_id = local.seoul_vpc_id

  filter {
    name   = "tag:Name"
    values = ["${var.seoul_name_prefix}-private-rt-*"]
  }
}

# 도쿄 → 서울. 🔴 이 라우트가 2부 「끊기」의 대상이다(계획서 2.3).
resource "aws_route" "tokyo_to_seoul" {
  for_each = var.enable_tokyo_route ? toset(data.aws_route_tables.tokyo_private.ids) : toset([])

  route_table_id            = each.value
  destination_cidr_block    = local.seoul_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.seoul.vpc_peering_connection_id
}

# 서울 → 도쿄. 돌아오는 길이라 끊기 대상이 **아니다** — 서울을 건드리지
# 않는 것이 2.3 의 요점이다.
resource "aws_route" "seoul_to_tokyo" {
  provider = aws.seoul

  for_each = toset(data.aws_route_tables.seoul_private.ids)

  route_table_id            = each.value
  destination_cidr_block    = local.tokyo_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.seoul.vpc_peering_connection_id
}
