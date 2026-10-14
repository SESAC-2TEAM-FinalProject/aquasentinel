terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # 2단계로 나눠서 쓴다(2026-10-14, 6단계 운영 안정화 — bootstrap state 백업).
  # 1) 최초 1회: 버킷이 아직 없으므로 backend 블록 없이(로컬 state로) apply —
  #    "backend를 만드는 코드가 그 backend를 쓸 수는 없다"는 제약 때문.
  # 2) 버킷이 생긴 뒤: 이 backend 블록을 추가하고 `terraform init
  #    -backend-config=backend.hcl -migrate-state`로 로컬 state를 그 버킷
  #    자신에게로 옮긴다 — 이후로는 다른 컴포넌트와 동일하게 S3가 state를
  #    관리하고(버저닝 이미 켜져 있어 이력도 같이 보존됨), 로컬 파일 하나에만
  #    의존하던 단일 장애점이 없어진다. backend.hcl은 다른 global/* 컴포넌트와
  #    동일하게 git에 올리지 않는다(backend.hcl.example 참고, 최초 1회 수동 생성).
  backend "s3" {
    use_lockfile = true
  }
}
