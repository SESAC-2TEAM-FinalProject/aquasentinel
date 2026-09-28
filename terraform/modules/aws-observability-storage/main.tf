locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # ---------------------------------------------------------------------------
  # Thanos(메트릭) / CloudNativePG-Barman Cloud(WAL·백업)는 버킷 하나를 prefix로
  # 나눠 공유한다. 워크로드별 IRSA 역할은 자기 prefix만 읽고 쓸 수 있어, 한
  # 워크로드가 뚫려도 다른 데이터는 건드릴 수 없다.
  #
  # Loki는 여기서 뺐다 — Loki Helm 차트의 "버킷+prefix" 지원(use_thanos_objstore/
  # storage_prefix)이 알려진 버그가 있어(grafana/loki#16599, #18784, #16543 등),
  # 안정적인 classic S3 스토리지 설정(버킷 단위만 받음)을 쓰려면 전용 버킷이
  # 필요하다. 아래 aws_s3_bucket.loki 참고.
  # ---------------------------------------------------------------------------
  workloads = {
    thanos = {
      namespace            = var.thanos_namespace
      service_account_name = var.thanos_service_account_name
      prefix               = "thanos/"
    }
    cloudnativepg = {
      namespace            = var.cloudnativepg_namespace
      service_account_name = var.cloudnativepg_service_account_name
      prefix               = "cloudnativepg/"
    }
  }
}

data "aws_caller_identity" "current" {}

# S3 버킷 이름은 전역 유일이어야 해서 계정ID를 붙인다.
resource "aws_s3_bucket" "this" {
  bucket = "${local.name_prefix}-observability-${data.aws_caller_identity.current.account_id}"

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-observability"
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

# 버저닝은 켜지 않는다 — Thanos/Loki/Barman Cloud 전부 자체 리텐션 로직으로
# 오래된 객체를 정리하므로, 버킷 버저닝까지 켜면 저장 비용만 이중으로 쌓인다.

# cloudnativepg/ prefix는 라이프사이클 규칙에서 제외한다. Barman Cloud가
# 자기 retention-policy로 WAL/베이스 백업을 관리하므로, S3가 별도로 만료시키면
# Barman이 모르는 사이 PITR 복구 가능 구간이 깨질 수 있다.
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "thanos-expiration"
    status = "Enabled"

    filter {
      prefix = local.workloads.thanos.prefix
    }

    expiration {
      days = var.thanos_retention_days
    }
  }

}

# ---------------------------------------------------------------------------
# Loki 전용 버킷 (위 설명 참고 — 공유 버킷+prefix 대신 분리)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "loki" {
  bucket = "${local.name_prefix}-loki-${data.aws_caller_identity.current.account_id}"

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-loki"
  })
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket = aws_s3_bucket.loki.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    id     = "loki-expiration"
    status = "Enabled"

    filter {}

    expiration {
      days = var.loki_retention_days
    }
  }
}

data "aws_iam_policy_document" "loki_assume" {
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
      values   = ["system:serviceaccount:${var.loki_namespace}:${var.loki_service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "loki" {
  name               = "${local.name_prefix}-loki-storage-role"
  assume_role_policy = data.aws_iam_policy_document.loki_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "loki_access" {
  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.loki.arn]
  }

  statement {
    sid       = "ReadWriteObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.loki.arn}/*"]
  }
}

resource "aws_iam_policy" "loki" {
  name   = "${local.name_prefix}-loki-storage-policy"
  policy = data.aws_iam_policy_document.loki_access.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "loki" {
  role       = aws_iam_role.loki.name
  policy_arn = aws_iam_policy.loki.arn
}

# ---------------------------------------------------------------------------
# 워크로드별 IRSA — aws-ingress 모듈의 ALB Controller 패턴과 동일하게,
# OIDC federated principal + sub 조건으로 특정 네임스페이스/서비스어카운트만
# AssumeRole 가능하게 한다.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  for_each = local.workloads

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
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = local.workloads

  name               = "${local.name_prefix}-${each.key}-storage-role"
  assume_role_policy = data.aws_iam_policy_document.assume[each.key].json
  tags               = var.tags
}

data "aws_iam_policy_document" "access" {
  for_each = local.workloads

  # prefix 조건 없이 허용한다 — barman-cloud(HeadBucket 호출, 파라미터에 prefix가
  # 없음)가 s3:ListBucket과 같은 액션이라 조건을 걸면 매치가 안 돼 막힌다(CNPG
  # 페일오버 테스트 중 "HeadBucket ... Forbidden"으로 실제 확인). 버킷 안 키 목록을
  # 볼 수 있는 것뿐이고, 실제 객체 읽기/쓰기는 아래 ReadWriteOwnPrefix로 여전히
  # 자기 prefix로만 제한된다.
  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]
  }

  statement {
    sid       = "ReadWriteOwnPrefix"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.this.arn}/${each.value.prefix}*"]
  }

  # barman-cloud(boto3 기반)가 리전 확인차 GetBucketLocation을 무조건 호출한다
  # — 버킷 리전 정보만 반환하는 읽기 전용 액션이라 prefix로 좁힐 필요 없음.
  # CNPG 페일오버 테스트 중 이게 빠져 WAL 아카이빙이 "Forbidden"으로 실패하는
  # 것을 실제로 확인한 뒤 추가.
  statement {
    sid       = "GetBucketLocation"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = [aws_s3_bucket.this.arn]
  }
}

resource "aws_iam_policy" "this" {
  for_each = local.workloads

  name   = "${local.name_prefix}-${each.key}-storage-policy"
  policy = data.aws_iam_policy_document.access[each.key].json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = local.workloads

  role       = aws_iam_role.this[each.key].name
  policy_arn = aws_iam_policy.this[each.key].arn
}
