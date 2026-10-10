# api-raw-store + observability-storage 버킷 통합 모듈 (경로 구조 개편안,
# 2026-10-10) — 버킷·버전관리·수명주기·복제만 담당한다. IRSA Role/Policy는
# 더 이상 이 모듈이 만들지 않는다(aws-irsa + 2-cluster 컴포넌트로 이동) —
# 버킷은 "재구축해도 안 지워지는 persistent" 수명이고 IRSA는 "클러스터와
# 같이 사라지는 rebuild" 수명이라 섞이면 안 된다는 게 개편 취지.
#
# prevent_destroy = true 고정(D3) — 이 모듈은 persistent 컴포넌트에서만
# 호출된다는 전제. 의도적으로 지워야 할 때는 이 블록을 잠깐 빼야 한다.
locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "this" {
  for_each = var.buckets

  bucket = "${local.name_prefix}-${each.value.name_suffix}-${data.aws_caller_identity.current.account_id}"

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-${each.value.name_suffix}"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = var.buckets

  bucket = aws_s3_bucket.this[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = var.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 크로스리전 복제(S3 CRR)는 양쪽 버킷 모두 버전관리가 켜져 있어야만 동작한다
# (AWS 하드 요구사항) — DR 회의(2026-09-30) 안건 7.
resource "aws_s3_bucket_versioning" "this" {
  for_each = { for k, v in var.buckets : k => v if v.enable_versioning }

  bucket = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = {
    for k, v in var.buckets : k => v
    if length(v.expiration_rules) > 0 || v.enable_versioning
  }

  bucket = aws_s3_bucket.this[each.key].id

  dynamic "rule" {
    for_each = each.value.expiration_rules

    content {
      id     = rule.value.id
      status = "Enabled"

      filter {
        prefix = rule.value.prefix
      }

      expiration {
        days = rule.value.days
      }
    }
  }

  # 버저닝이 켜진 버킷은 과거 버전이 무기한 쌓이는 걸 막는다(복제 전제조건이라
  # 버저닝을 끌 수 없음). cloudnativepg/ prefix처럼 "현재 버전 만료" 규칙에서
  # 의도적으로 제외된 prefix가 있어도, noncurrent-version-expiration은 버킷
  # 전체에 걸어야 한다 — 안 그러면 Barman 자체 리텐션이 지운 과거 버전이
  # 버저닝 때문에 S3에 그림자로 남아 비용이 샌다(observability-storage 모듈
  # 원본 주석 그대로 이전).
  dynamic "rule" {
    for_each = each.value.enable_versioning ? [1] : []

    content {
      id     = "noncurrent-version-expiration"
      status = "Enabled"

      filter {}

      noncurrent_version_expiration {
        noncurrent_days = each.value.noncurrent_version_expiration_days
      }
    }
  }
}

# ---------------------------------------------------------------------------
# S3 Cross-Region Replication — 복제가 필요한 버킷마다 역할 하나씩.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "replication_assume" {
  for_each = { for k, v in var.buckets : k => v if v.enable_cross_region_replication }

  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replication" {
  for_each = { for k, v in var.buckets : k => v if v.enable_cross_region_replication }

  name               = "${local.name_prefix}-${each.value.name_suffix}-replication-role"
  assume_role_policy = data.aws_iam_policy_document.replication_assume[each.key].json
  tags               = var.tags
}

data "aws_iam_policy_document" "replication_access" {
  for_each = { for k, v in var.buckets : k => v if v.enable_cross_region_replication }

  statement {
    sid       = "SourceBucketRead"
    effect    = "Allow"
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [aws_s3_bucket.this[each.key].arn]
  }

  statement {
    sid       = "SourceObjectVersionRead"
    effect    = "Allow"
    actions   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
    resources = ["${aws_s3_bucket.this[each.key].arn}/*"]
  }

  statement {
    sid       = "DestinationReplicate"
    effect    = "Allow"
    actions   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
    resources = ["${each.value.replication_destination_bucket_arn}/*"]
  }
}

resource "aws_iam_policy" "replication" {
  for_each = { for k, v in var.buckets : k => v if v.enable_cross_region_replication }

  name   = "${local.name_prefix}-${each.value.name_suffix}-replication-policy"
  policy = data.aws_iam_policy_document.replication_access[each.key].json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "replication" {
  for_each = { for k, v in var.buckets : k => v if v.enable_cross_region_replication }

  role       = aws_iam_role.replication[each.key].name
  policy_arn = aws_iam_policy.replication[each.key].arn
}

resource "aws_s3_bucket_replication_configuration" "this" {
  for_each = { for k, v in var.buckets : k => v if v.enable_cross_region_replication }

  # 복제는 버저닝이 켜진 버킷에서만 설정 가능하다는 AWS 요구사항을 Terraform
  # 의존성 그래프에도 명시적으로 강제한다.
  depends_on = [aws_s3_bucket_versioning.this]

  bucket = aws_s3_bucket.this[each.key].id
  role   = aws_iam_role.replication[each.key].arn

  rule {
    id     = "replicate-to-tokyo"
    status = "Enabled"

    filter {}

    # Barman Cloud의 자체 리텐션이 지운 객체(delete marker)도 그대로 복제해야,
    # 도쿄 쪽에 서울이 이미 정리한 과거 백업이 영영 안 지워지고 남는 걸 막는다.
    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = each.value.replication_destination_bucket_arn
      storage_class = "STANDARD"
    }
  }
}
