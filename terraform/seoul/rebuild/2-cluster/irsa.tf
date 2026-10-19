# 워크로드별 IRSA — 구 aws-eso/aws-ingress/aws-api-raw-store/
# aws-observability-storage 모듈의 IAM 정책 JSON을 재작성 없이 그대로
# 옮겼다. thanos/cloudnativepg의 service_account 이름은 실제 사고(2026-10-08
# thanos-sidecar S3 Access Denied, CNPG WAL 아카이빙 AccessDenied)로 확인된
# 값이다 — 모듈 기본값과 실제 생성되는 ServiceAccount 이름이 달라서 트러스트
# 정책 sub 조건이 안 맞았던 사고. 이 컴포넌트에서는 역할 ARN과 SA 이름을
# 같은 곳(여기)에서 함께 관리해 같은 사고가 재발하기 더 어렵게 한다 —
# 다만 thanos/cloudnativepg처럼 SA를 Terraform이 아니라 차트/오퍼레이터가
# 만드는 경우는 여전히 이름을 "맞춰 적어야" 한다는 한계는 남는다(경로
# 구조 개편안 4.2의 한계 설명과 동일).

locals {
  persistent = data.terraform_remote_state.persistent.outputs
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
# External Secrets Operator — 이 프로젝트 소관 시크릿("${name_prefix}-*")만
# 읽을 수 있게 범위를 좁힌다. PushSecret 쓰기 권한은 더 좁게(api-module-*)
# 한정한다 — ESO가 뚫려도 임의의 프로젝트 시크릿을 덮어쓰지 못하게.
# ---------------------------------------------------------------------------

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

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

  # PushSecret(ESO)이 CNPG 앱 시크릿을 Secrets Manager로 밀어넣을 때 쓴다
  # (CNPG 공식 권장 크로스 네임스페이스 패턴). ESO의 PushSecret이 매
  # 동기화마다 리소스 정책을 지우는 호출을 무조건 시도한다(리소스 정책이
  # 없어도) — 실제 라이브 apply에서 AccessDenied로 확인된 후 추가.
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
# Thanos — observability 버킷의 thanos/ prefix만 접근. ListBucket은 prefix
# 조건 없이 허용한다 — barman-cloud류 HeadBucket 호출 패턴과 같은 이유로
# s3:ListBucket 자체엔 조건을 걸 수 없다(버킷 안 키 목록을 볼 수 있을 뿐,
# 실제 객체 읽기/쓰기는 ReadWriteOwnPrefix로 자기 prefix만 허용됨).
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
# CloudNativePG(Barman Cloud) — observability 버킷의 cloudnativepg/ prefix만
# 접근. 위 thanos와 같은 이유로 ListBucket·GetBucketLocation은 prefix 조건
# 없이 허용(barman-cloud의 HeadBucket/GetBucketLocation 호출에 prefix
# 파라미터가 없어 조건을 걸면 CNPG 페일오버 테스트 중 "Forbidden"으로
# 실패했던 적이 있음).
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

  # 다른 계정의 백업에서 복구할 때만 붙는다(시험 구역 — D-17 · SIM-09a).
  # cnpg_restore_source_bucket_arn 이 비어 있으면 statement 자체가 생기지 않아
  # 운영 apply 는 영향을 받지 않는다.
  #
  # S3 계정 간 접근은 **양쪽이 다 허용**해야 한다. 원본 계정의 버킷 정책만
  # 열면(리소스 쪽) 읽는 쪽 역할에 권한이 없어 AccessDenied 로 끝난다 —
  # 그 짝이 이 블록(신원 쪽)이다. 버킷 정책은 원본 계정
  # seoul/persistent 의 testfield_account_ids 가 만든다.
  #
  # ListBucket·GetBucketLocation 에 조건을 걸지 않는 이유는 위 머리말과 같다
  # (barman-cloud HeadBucket 에 prefix 가 없다). 도쿄 CrossRegion* 와 같은 모양.
  dynamic "statement" {
    for_each = var.cnpg_restore_source_bucket_arn == "" ? [] : [1]
    content {
      sid       = "CrossAccountRestoreBucketLevel"
      effect    = "Allow"
      actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
      resources = [var.cnpg_restore_source_bucket_arn]
    }
  }

  dynamic "statement" {
    for_each = var.cnpg_restore_source_bucket_arn == "" ? [] : [1]
    content {
      sid       = "CrossAccountRestoreReadPrefix"
      effect    = "Allow"
      actions   = ["s3:GetObject"]
      resources = ["${var.cnpg_restore_source_bucket_arn}/${var.cnpg_restore_source_prefix}*"]
    }
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
# Loki — 공유 버킷+prefix 대신 전용 버킷(Loki Helm 차트의 버킷+prefix 지원
# 버그 때문, seoul/persistent 주석 참고). 버킷 전체를 쓰므로 prefix 조건이
# 없다.
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
# api-raw-store collector/processor — collector는 원문을 쓰고 저장 직후
# 사전 읽기로 결과 코드만 확인한다(PutObject+GetObject). processor는 읽기만
# 한다(reprocess Job·completeness-check 포함, 둘 다 processor 이미지 재사용) —
# 원문은 collector만 만든다는 설계(제작계획서 2.1절)를 IAM으로도 강제한다.
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

# ---------------------------------------------------------------------------
# GitLab Runner(EKS 자체 러너, api-module/web/gitops 레포 CI용)의 ECR push/pull
# — ESO/Loki와 같은 패턴(SA를 미리 만들고 Helm values는 create: false로 참조).
# 도쿄는 CI가 돌지 않으므로 이 러너 자체가 필요 없다(서울 전용, 이 모듈
# 호출도 seoul/rebuild/2-cluster에만 있음). Terraform 레포 CI(plan/apply)는
# 이 러너가 아니라 GitLab.com 공유 러너를 쓴다(modules/aws-cicd 주석 참고 —
# 클러스터를 destroy하는 작업이 그 클러스터 안 러너에서 돌면 순환 의존이
# 생김) — 그래서 이 Role은 ECR 권한만 가진다.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "gitlab_runner_ecr" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushPullScoped"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    # aws-registry 모듈의 레포 이름(${name_prefix}/*)과 동일한 접두사로 범위를
    # 좁힌다.
    resources = ["arn:aws:ecr:${var.region}:*:repository/${local.name_prefix}/*"]
  }
}

resource "aws_iam_policy" "gitlab_runner_ecr" {
  name   = "${local.name_prefix}-gitlab-runner-ecr"
  policy = data.aws_iam_policy_document.gitlab_runner_ecr.json
  tags   = var.tags
}

module "gitlab_runner_irsa" {
  source = "../../../modules/aws-irsa"

  role_name                  = "${local.name_prefix}-gitlab-runner-build"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  namespace_service_accounts = ["gitlab-runner:gitlab-runner-build"]
  policy_arns                = { ecr = aws_iam_policy.gitlab_runner_ecr.arn }
  tags                       = var.tags
}

# ---------------------------------------------------------------------------
# Grafana — CloudWatch 데이터소스용(웹팀 요청, 2026-10-16: 외부 진입 성공률
# Route53 헬스체크·ACM 인증서 만료 경보가 CloudWatch 전용 지표라 필요).
# Grafana 공식 문서의 "metrics-only" 권장 정책에서 Performance Insights
# (pi:GetResourceMetrics)만 뺐다 — RDS를 안 쓰므로 불필요.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "grafana_cloudwatch" {
  statement {
    sid    = "AllowReadingMetricsFromCloudWatch"
    effect = "Allow"
    actions = [
      "cloudwatch:DescribeAlarmsForMetric",
      "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetInsightRuleReport",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "AllowReadingTagsInstancesRegionsFromEC2"
    effect    = "Allow"
    actions   = ["ec2:DescribeTags", "ec2:DescribeInstances", "ec2:DescribeRegions"]
    resources = ["*"]
  }

  statement {
    sid       = "AllowReadingResourcesForTags"
    effect    = "Allow"
    actions   = ["tag:GetResources"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "grafana_cloudwatch" {
  name   = "${local.name_prefix}-grafana-cloudwatch-policy"
  policy = data.aws_iam_policy_document.grafana_cloudwatch.json
  tags   = var.tags
}

module "grafana_irsa" {
  source = "../../../modules/aws-irsa"

  role_name                  = "${local.name_prefix}-grafana-cloudwatch-role"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  namespace_service_accounts = ["${var.grafana_namespace}:${var.grafana_service_account_name}"]
  policy_arns                = { cloudwatch = aws_iam_policy.grafana_cloudwatch.arn }
  tags                       = var.tags
}
