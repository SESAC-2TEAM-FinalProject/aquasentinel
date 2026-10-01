locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# API 모듈의 원문(raw API 응답) 저장 전용 버킷 — Thanos/Loki/CloudNativePG
# 관측 버킷과는 분리한다(서로 다른 소유·접근 패턴). DB에는 색인 행만 두고
# 본문은 여기에 둔다(제작계획서 2.3절 — MySQL TEXT 64KB 한계, sooList 1년
# 응답이 약 4MB라 DB에 못 넣음). 키 형식은 모듈이 정한다:
# raw/{api}/{yyyy}/{mm}/{dd}/{epoch_ms}_{tag}.json
#
# 라이프사이클 규칙은 두지 않는다 — 원문 보관 기간 정책이 아직 팀 결정
# 사항으로 남아있다(제작계획서 11절, v1.5 12.1절 미결). 결정되면 이 리소스에
# aws_s3_bucket_lifecycle_configuration을 추가한다.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  bucket = "${local.name_prefix}-raw-store-${data.aws_caller_identity.current.account_id}"

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-raw-store"
  })
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 크로스리전 복제(S3 Cross-Region Replication)는 양쪽 버킷 모두 버전관리가
# 켜져 있어야만 동작한다(AWS 하드 요구사항) — DR 회의(2026-09-30) 안건 7에서
# 복제를 켜기로 확정하면서 추가한다.
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 원문(raw) 자체의 보관 기간 정책은 여전히 미결(위 설명 참고) — 현재 버전에
# expiration 규칙은 걸지 않는다. 다만 버저닝 때문에 생기는 과거 버전은 별개
# 문제라, 여기만 정리한다. collector가 같은 키를 두 번 덮어쓸 일은 거의
# 없지만(키 자체에 epoch_ms가 들어감), 혹시 모를 재시도/재처리로 생기는
# 과거 버전까지 무기한 쌓이는 걸 막는다.
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "noncurrent-version-expiration"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }
}

# ---------------------------------------------------------------------------
# S3 Cross-Region Replication — 서울(소스)에서만 켠다. 도쿄는 복제 대상
# (destination)일 뿐이라 이 블록이 전부 count = 0으로 꺼진 채 버전관리만
# 적용받는다.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "replication_assume" {
  count = var.enable_cross_region_replication ? 1 : 0

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
  count = var.enable_cross_region_replication ? 1 : 0

  name               = "${local.name_prefix}-raw-store-replication-role"
  assume_role_policy = data.aws_iam_policy_document.replication_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "replication_access" {
  count = var.enable_cross_region_replication ? 1 : 0

  statement {
    sid       = "SourceBucketRead"
    effect    = "Allow"
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]
  }

  statement {
    sid       = "SourceObjectVersionRead"
    effect    = "Allow"
    actions   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
    resources = ["${aws_s3_bucket.this.arn}/*"]
  }

  statement {
    sid       = "DestinationReplicate"
    effect    = "Allow"
    actions   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
    resources = ["${var.replication_destination_bucket_arn}/*"]
  }
}

resource "aws_iam_policy" "replication" {
  count = var.enable_cross_region_replication ? 1 : 0

  name   = "${local.name_prefix}-raw-store-replication-policy"
  policy = data.aws_iam_policy_document.replication_access[0].json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "replication" {
  count = var.enable_cross_region_replication ? 1 : 0

  role       = aws_iam_role.replication[0].name
  policy_arn = aws_iam_policy.replication[0].arn
}

resource "aws_s3_bucket_replication_configuration" "this" {
  count = var.enable_cross_region_replication ? 1 : 0

  depends_on = [aws_s3_bucket_versioning.this]

  bucket = aws_s3_bucket.this.id
  role   = aws_iam_role.replication[0].arn

  rule {
    id     = "replicate-to-tokyo"
    status = "Enabled"

    filter {}

    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = var.replication_destination_bucket_arn
      storage_class = "STANDARD"
    }
  }
}

# ---------------------------------------------------------------------------
# collector — 원문을 쓰고, 저장 직후 사전 읽기로 결과 코드만 확인한다
# (제작계획서 2.3절) → PutObject + GetObject 둘 다 필요.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "collector_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.collector_service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "collector" {
  name               = "${local.name_prefix}-raw-store-collector-role"
  assume_role_policy = data.aws_iam_policy_document.collector_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "collector_access" {
  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]
  }

  statement {
    sid       = "WriteAndReadOwnObjects"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]
  }
}

resource "aws_iam_policy" "collector" {
  name   = "${local.name_prefix}-raw-store-collector-policy"
  policy = data.aws_iam_policy_document.collector_access.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "collector" {
  role       = aws_iam_role.collector.name
  policy_arn = aws_iam_policy.collector.arn
}

# ---------------------------------------------------------------------------
# processor — 원문을 읽기만 한다(해석·정규화 입력, reprocess Job 포함).
# 쓰기 권한은 주지 않는다 — 원문은 collector만 만든다(제작계획서 2.1절
# "collector는 판정하지 않는다. 원문과 요청 메타데이터만 남긴다").
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "processor_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.processor_service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "processor" {
  name               = "${local.name_prefix}-raw-store-processor-role"
  assume_role_policy = data.aws_iam_policy_document.processor_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "processor_access" {
  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]
  }

  statement {
    sid       = "ReadOnlyObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]
  }
}

resource "aws_iam_policy" "processor" {
  name   = "${local.name_prefix}-raw-store-processor-policy"
  policy = data.aws_iam_policy_document.processor_access.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "processor" {
  role       = aws_iam_role.processor.name
  policy_arn = aws_iam_policy.processor.arn
}
