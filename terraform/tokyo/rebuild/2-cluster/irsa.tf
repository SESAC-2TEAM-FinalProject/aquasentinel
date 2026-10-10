# 워크로드별 IRSA — 서울 2-cluster(irsa.tf)와 같은 정책 JSON을 그대로 쓴다.
# 유일한 차이는 cloudnativepg 역할: 도쿄는 CNPG Replica Cluster(방식 B, DR
# 회의 2026-09-30 안건 7)가 서울 observability 버킷의 cloudnativepg/ prefix를
# 읽어 복구해야 해서, 자기 버킷 권한 외에 서울 버킷에 대한 읽기 전용 권한이
# 추가된다(아래 cross_region_read 블록). GitLab Runner IRSA는 없다 — 도쿄는
# CI가 돌지 않는다(서울 irsa.tf 주석 참고).

locals {
  persistent  = data.terraform_remote_state.persistent.outputs
  name_prefix = "${var.project_name}-${var.environment}"
}

data "terraform_remote_state" "seoul_persistent" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "seoul/persistent/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "lbc" {
  name   = "${var.project_name}-${var.environment}-aws-lbc-policy"
  policy = file("${path.module}/policies/aws-load-balancer-controller-iam-policy.json")
  tags   = var.tags
}

module "lbc_irsa" {
  source = "../../../modules/aws-irsa"

  role_name                  = "${var.project_name}-${var.environment}-aws-lbc-role"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  namespace_service_accounts = ["${var.lbc_namespace}:${var.lbc_service_account_name}"]
  policy_arns                = { lbc = aws_iam_policy.lbc.arn }
  tags                       = var.tags
}

# ---------------------------------------------------------------------------
# External Secrets Operator
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "eso_access" {
  statement {
    sid    = "ReadAnyProjectSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = ["arn:aws:secretsmanager:*:*:secret:${local.name_prefix}-*"]
  }

  statement {
    sid    = "PushSecretWriteScoped"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:PutSecretValue",
      "secretsmanager:TagResource",
      "secretsmanager:DeleteSecret",
      "secretsmanager:DeleteResourcePolicy",
      "secretsmanager:PutResourcePolicy",
    ]
    resources = ["arn:aws:secretsmanager:*:*:secret:${local.name_prefix}-api-module-*"]
  }
}

resource "aws_iam_policy" "eso" {
  name   = "${local.name_prefix}-eso-policy"
  policy = data.aws_iam_policy_document.eso_access.json
  tags   = var.tags
}

module "eso_irsa" {
  source = "../../../modules/aws-irsa"

  role_name                  = "${local.name_prefix}-eso-role"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  namespace_service_accounts = ["${var.eso_namespace}:${var.eso_service_account_name}"]
  policy_arns                = { eso = aws_iam_policy.eso.arn }
  tags                       = var.tags
}

# ---------------------------------------------------------------------------
# Thanos — observability 버킷의 thanos/ prefix만 접근(자기 버킷, 복제로 서울
# 메트릭도 들어와 있지만 도쿄 자체 Thanos는 자기 리전 메트릭만 적재).
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "thanos_access" {
  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.persistent.bucket_arns["observability"]]
  }

  statement {
    sid       = "ReadWriteOwnPrefix"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.persistent.bucket_arns["observability"]}/${local.persistent.thanos_prefix}*"]
  }

  statement {
    sid       = "GetBucketLocation"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = [local.persistent.bucket_arns["observability"]]
  }
}

resource "aws_iam_policy" "thanos" {
  name   = "${local.name_prefix}-thanos-storage-policy"
  policy = data.aws_iam_policy_document.thanos_access.json
  tags   = var.tags
}

module "thanos_irsa" {
  source = "../../../modules/aws-irsa"

  role_name                  = "${local.name_prefix}-thanos-storage-role"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  namespace_service_accounts = ["${var.thanos_namespace}:${var.thanos_service_account_name}"]
  policy_arns                = { thanos = aws_iam_policy.thanos.arn }
  tags                       = var.tags
}

# ---------------------------------------------------------------------------
# CloudNativePG(Barman Cloud) — 자기 버킷의 cloudnativepg/ prefix 읽기/쓰기에
# 더해, 서울 observability 버킷의 cloudnativepg/ prefix에 대한 읽기 전용 권한을
# 추가로 붙인다(CrossRegion* 문). 새 역할을 따로 만들지 않고 이 역할에 정책만
# 하나 더 붙이는 구조 — 서울 회신 문서에서 그대로 가져온 설계(구
# aws-observability-storage 모듈의 enable_cross_region_read와 동일 로직).
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cloudnativepg_access" {
  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.persistent.bucket_arns["observability"]]
  }

  statement {
    sid       = "ReadWriteOwnPrefix"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.persistent.bucket_arns["observability"]}/${local.persistent.cloudnativepg_prefix}*"]
  }

  statement {
    sid       = "GetBucketLocation"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = [local.persistent.bucket_arns["observability"]]
  }

  # barman-cloud의 HeadBucket 호출은 prefix 파라미터가 없어, 자기 버킷 정책과
  # 같은 이유로 조건 없이 허용한다(서울 cloudnativepg_access와 동일 근거).
  statement {
    sid       = "CrossRegionListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [data.terraform_remote_state.seoul_persistent.outputs.bucket_arns["observability"]]
  }

  statement {
    sid       = "CrossRegionReadPrefix"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${data.terraform_remote_state.seoul_persistent.outputs.bucket_arns["observability"]}/${data.terraform_remote_state.seoul_persistent.outputs.cloudnativepg_prefix}*"]
  }

  statement {
    sid       = "CrossRegionGetBucketLocation"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation"]
    resources = [data.terraform_remote_state.seoul_persistent.outputs.bucket_arns["observability"]]
  }
}

resource "aws_iam_policy" "cloudnativepg" {
  name   = "${local.name_prefix}-cloudnativepg-storage-policy"
  policy = data.aws_iam_policy_document.cloudnativepg_access.json
  tags   = var.tags
}

module "cloudnativepg_irsa" {
  source = "../../../modules/aws-irsa"

  role_name                  = "${local.name_prefix}-cloudnativepg-storage-role"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  namespace_service_accounts = ["${var.cloudnativepg_namespace}:${var.cloudnativepg_service_account_name}"]
  policy_arns                = { cloudnativepg = aws_iam_policy.cloudnativepg.arn }
  tags                       = var.tags
}

# ---------------------------------------------------------------------------
# Loki — 전용 버킷(서울과 동일 이유, persistent 주석 참고).
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "loki_access" {
  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.persistent.bucket_arns["loki"]]
  }

  statement {
    sid       = "ReadWriteObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.persistent.bucket_arns["loki"]}/*"]
  }
}

resource "aws_iam_policy" "loki" {
  name   = "${local.name_prefix}-loki-storage-policy"
  policy = data.aws_iam_policy_document.loki_access.json
  tags   = var.tags
}

module "loki_irsa" {
  source = "../../../modules/aws-irsa"

  role_name                  = "${local.name_prefix}-loki-storage-role"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  namespace_service_accounts = ["${var.loki_namespace}:${var.loki_service_account_name}"]
  policy_arns                = { loki = aws_iam_policy.loki.arn }
  tags                       = var.tags
}

# ---------------------------------------------------------------------------
# api-raw-store collector/processor — 평소엔 도쿄에서 안 돌지만(DR 대기),
# 페일오버 시 즉시 쓸 수 있도록 역할을 미리 만들어둔다(서울과 동일 패턴).
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "collector_access" {
  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.persistent.bucket_arns["api_raw_store"]]
  }

  statement {
    sid       = "WriteAndReadOwnObjects"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${local.persistent.bucket_arns["api_raw_store"]}/*"]
  }
}

resource "aws_iam_policy" "collector" {
  name   = "${local.name_prefix}-raw-store-collector-policy"
  policy = data.aws_iam_policy_document.collector_access.json
  tags   = var.tags
}

module "collector_irsa" {
  source = "../../../modules/aws-irsa"

  role_name                  = "${local.name_prefix}-raw-store-collector-role"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  namespace_service_accounts = ["${var.api_module_namespace}:${var.collector_service_account_name}"]
  policy_arns                = { collector = aws_iam_policy.collector.arn }
  tags                       = var.tags
}

data "aws_iam_policy_document" "processor_access" {
  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.persistent.bucket_arns["api_raw_store"]]
  }

  statement {
    sid       = "ReadOnlyObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${local.persistent.bucket_arns["api_raw_store"]}/*"]
  }
}

resource "aws_iam_policy" "processor" {
  name   = "${local.name_prefix}-raw-store-processor-policy"
  policy = data.aws_iam_policy_document.processor_access.json
  tags   = var.tags
}

module "processor_irsa" {
  source = "../../../modules/aws-irsa"

  role_name                  = "${local.name_prefix}-raw-store-processor-role"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  namespace_service_accounts = ["${var.api_module_namespace}:${var.processor_service_account_name}"]
  policy_arns                = { processor = aws_iam_policy.processor.arn }
  tags                       = var.tags
}
