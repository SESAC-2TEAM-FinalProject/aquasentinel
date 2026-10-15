locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# 같은 계정 안에서의 리전간 복제라 registry_id는 우리 계정 ID 그대로 쓴다 —
# 계정간 복제가 아니므로 대상 레지스트리에 별도 리소스 정책을 걸 필요는 없다
# (AWS가 서비스 연결 역할로 내부 처리).
data "aws_caller_identity" "current" {
  count = var.enable_cross_region_replication ? 1 : 0
}

resource "aws_ecr_replication_configuration" "this" {
  count = var.enable_cross_region_replication ? 1 : 0

  replication_configuration {
    rule {
      destination {
        region      = var.replication_destination_region
        registry_id = data.aws_caller_identity.current[0].account_id
      }

      # name_prefix로 시작하는 레포(이 환경이 만든 전부)만 복제 대상으로 한정 —
      # 계정에 나중에 다른 프로젝트 레포가 추가돼도 영향받지 않는다.
      repository_filter {
        filter      = local.name_prefix
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name                 = "${local.name_prefix}/${each.value}"
  image_tag_mutability = var.image_tag_mutability

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-${each.value}"
  })
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "태그 없는 이미지는 ${var.untagged_image_expiry_days}일 후 정리"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_image_expiry_days
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# 다른 계정(시험 구역)이 이미지를 **받기만** 하게 허용 — 운영과 같은 이미지를 쓰기 위해(GitOps 일원화 v2 5절 "ECR pull 허용").
# 쓰기(push) · 삭제 권한은 주지 않는다. 받는 쪽 계정의 노드 역할에도 ECR 읽기 권한(AmazonEC2ContainerRegistryReadOnly)이 있어야 한다.
# 목록이 비어 있으면 아무것도 만들지 않는다(기본값 — 운영 변화 없음).
resource "aws_ecr_repository_policy" "pull_only" {
  for_each = length(var.pull_only_account_ids) > 0 ? aws_ecr_repository.this : {}

  repository = each.value.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PullOnlyFromOtherAccounts"
        Effect    = "Allow"
        Principal = { AWS = [for id in var.pull_only_account_ids : "arn:aws:iam::${id}:root"] }
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability",
        ]
      }
    ]
  })
}
