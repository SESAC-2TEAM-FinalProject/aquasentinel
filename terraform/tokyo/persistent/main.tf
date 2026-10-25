# 도쿄 persistent — 클러스터 유무와 무관하게 상시 운영(D4, 2026-10-10 확정).
# S3 버킷 2개(복제 대상)와 ACM 인증서만 존재한다. ECR은 없음 — 서울
# registry의 Cross-Region Replication이 AWS 쪽에서 자동으로 리포지토리를
# 복제해주므로, 도쿄 쪽에 Terraform이 관리할 ECR 리소스 자체가 없다
# (경로 구조 개편안 4.1 — "registry는 전달용 output만 있었다"를 실제
# state 조회로 확인, 2026-10-10 회신 문서 5절).

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
      component   = "persistent"
    }
  }
}

locals {
  # 서울 persistent가 복제해 넣는 prefix와 반드시 같은 값이어야 한다(S3 복제는
  # 키를 그대로 복사하므로). 2-cluster/3-gitops가 이 output을 그대로 참조해
  # 값이 한쪽만 바뀌는 사고를 막는다(seoul/persistent와 동일 패턴).
  thanos_prefix        = "thanos/"
  cloudnativepg_prefix = "cloudnativepg/"

  # 🔴 도쿄 CNPG 가 **자기 백업을 쓰는** 경로 (2026-10-25 신설).
  #
  # 위 cloudnativepg_prefix 는 "서울 백업의 복제본을 읽는" 경로다 — 서울
  # observability 버킷에 `replicate-to-tokyo` 복제 규칙이 걸려 있어 서울의
  # `cloudnativepg/…` 키가 그대로 이 버킷에 복사된다. 그래서 값이 같아야 한다.
  #
  # 문제는 도쿄가 **쓰는** 경로도 같은 값이었다는 것이다. CNPG 는 복구를 시작하기
  # 전에 `barman-cloud-check-wal-archive` 로 **자기 아카이브가 비어 있는지** 검사
  # 하는데, 그 자리에 복제본이 계속 쌓이고 있어 영구히 거부당했다:
  #
  #     ERROR: WAL archive check failed for server aquasentinel-pg: Expected empty archive
  #     s3://aquasentinel-dr-tokyo-observability-…/cloudnativepg/
  #
  # 2026-10-25 도쿄 최초 기동에서 복구 Job 이 7회 연속 Error 로 드러났다. 실제
  # 리전 장애 때도 똑같이 막히므로 DR 2단계가 성립하지 않는 상태였다.
  #
  # 🔴 읽는 곳과 쓰는 곳을 가른다. 복제본은 읽기 전용으로 두고(복제가 계속
  # 덮어쓰므로 도쿄가 그 자리에 쓰면 안 된다), 도쿄 자신의 백업은 이 경로로
  # 보낸다. 서울은 이 값을 쓰지 않는다 — 도쿄에만 있는 개념이다.
  cloudnativepg_write_prefix = "cloudnativepg-tokyo/"
}

module "storage" {
  source = "../../modules/aws-storage"

  project_name = var.project_name
  environment  = var.environment

  buckets = {
    observability = {
      name_suffix       = "observability"
      enable_versioning = true # 복제 대상이 되려면 버저닝 필수(AWS 요구사항)
    }
    api_raw_store = {
      name_suffix       = "raw-store"
      enable_versioning = true
    }
    # Loki 전용 버킷 — 서울과 같은 이유로 공유 버킷+prefix 를 쓸 수 없다
    # (seoul/persistent/main.tf 주석: Loki Helm 차트의 use_thanos_objstore/
    # storage_prefix 지원에 알려진 버그가 있어 classic S3 설정을 쓰는데, 그건
    # 버킷 단위만 받는다 — grafana/loki#16599·#18784·#16543).
    #
    # 🔴 서울에는 있는데 여기만 없어서, 도쿄 전환을 시도하면 **plan 단계에서
    # 멈춰 있었다**("key does not identify an element"). 막히는 곳이 두 군데고
    # 적용 순서가 1→2→3 이라 **2-cluster 가 먼저** 걸린다:
    #   - rebuild/2-cluster/irsa.tf  : local.persistent.bucket_arns["loki"]
    #                                  (Loki 파드의 S3 쓰기 권한 IRSA)
    #   - rebuild/3-gitops/applications.tf : bucket_names["loki"] (Loki values)
    # 2026-10-19 에 3-gitops 쪽만 발견해 적어 뒀는데, 10-22 전수 대조에서
    # 2-cluster 가 먼저라는 걸 확인했다. 즉 이 버킷이 없으면 도쿄는 2단계에서
    # 더 못 간다.
    #
    # 도쿄 Loki 는 자기 리전 로그만 담는다 — 서울에서 복제해 오는 대상이
    # 아니므로 버저닝도 필요 없다(서울 쪽 loki 버킷과 동일한 판단).
    loki = {
      name_suffix = "loki"
      expiration_rules = [
        { id = "loki-expiration", days = var.loki_retention_days }
      ]
    }
  }

  tags = var.tags
}

module "dns" {
  source = "../../modules/aws-dns"

  project_name = var.project_name
  environment  = var.environment
  domain_name  = var.domain_name

  create_certificate      = true
  enable_failover_routing = false # 레코드는 4-edge 컴포넌트가 담당
}
