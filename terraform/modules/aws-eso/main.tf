locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ---------------------------------------------------------------------------
# External Secrets Operator용 IRSA
#
# ESO는 AWS Secrets Manager에 있는 값을 K8s Secret으로 동기화하는 역할만 한다.
# 이 프로젝트 소관 시크릿("${name_prefix}-*")만 읽을 수 있게 범위를 좁혀서,
# ESO가 뚫려도 다른 프로젝트/계정 전역 시크릿엔 접근할 수 없게 한다.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
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
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${local.name_prefix}-eso-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "access" {
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
  # (CNPG 공식 권장 크로스 네임스페이스 패턴 — PostgreSQL 가이드 2.3절 참고).
  # 쓰기 권한은 읽기보다 좁게, push 대상 접두사로만 한정한다 — ESO가 뚫려도
  # 임의의 프로젝트 시크릿을 덮어쓰지 못하게.
  statement {
    sid    = "PushSecretWriteScoped"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:PutSecretValue",
      "secretsmanager:TagResource",
      "secretsmanager:DeleteSecret",
    ]
    resources = ["arn:aws:secretsmanager:*:*:secret:${local.name_prefix}-api-module-*"]
  }
}

resource "aws_iam_policy" "this" {
  name   = "${local.name_prefix}-eso-policy"
  policy = data.aws_iam_policy_document.access.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}
