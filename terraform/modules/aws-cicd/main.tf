locals {
  name_prefix = var.project_name
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC Provider — 계정에 1개만 존재하면 된다.
# EKS 파드용 OIDC(모듈 aws-eks)와 정확히 같은 메커니즘이고, 신뢰 대상만 다르다.
# ---------------------------------------------------------------------------

data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Plan 전용 역할 — 모든 브랜치/PR에서 사용 가능. 읽기 전용이라 위험도가 낮다.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "plan_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "${local.name_prefix}-github-terraform-plan"
  assume_role_policy = data.aws_iam_policy_document.plan_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ---------------------------------------------------------------------------
# Apply 전용 역할 — 지정한 브랜치(기본 main)에서만 사용 가능.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "apply_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/${var.github_branch}"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apply" {
  name               = "${local.name_prefix}-github-terraform-apply"
  assume_role_policy = data.aws_iam_policy_document.apply_assume.json
  tags               = var.tags
}

# PowerUserAccess는 IAM/Organizations 관리를 제외한 전 서비스를 커버한다.
# 이 프로젝트의 모듈(aws-eks/aws-data/aws-ingress/aws-dns)이 전부 IAM 역할·정책을
# 직접 만들기 때문에, apply 역할도 IAM 권한이 필요하다 — 이건 Terraform으로 IAM을
# 관리하는 모든 CI 파이프라인이 구조적으로 안고 가는 한계다(완전한 최소권한 불가).
# 대신 아래 커스텀 정책으로 "${project_name}-*로 시작하는 IAM 엔티티만" 건드릴 수
# 있게 범위를 좁혀 자기권한상승(self-privilege-escalation) 반경을 제한한다.
resource "aws_iam_role_policy_attachment" "apply_poweruser" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "apply_iam_scoped" {
  statement {
    sid    = "ScopedIamRoleAndPolicyManagement"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:TagPolicy",
      "iam:PassRole",
    ]
    resources = [
      "arn:aws:iam::*:role/${var.project_name}-*",
      "arn:aws:iam::*:policy/${var.project_name}-*",
    ]
  }

  # OIDC provider ARN은 이름이 아니라 issuer URL 기반이라 프로젝트 접두사로
  # 범위를 좁힐 수 없다 — eks/cicd 모듈이 OIDC provider를 만들 때 필요한 예외.
  statement {
    sid    = "OidcProviderManagement"
    effect = "Allow"
    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
    ]
    resources = ["arn:aws:iam::*:oidc-provider/*"]
  }
}

resource "aws_iam_policy" "apply_iam_scoped" {
  name   = "${local.name_prefix}-github-apply-iam-scoped"
  policy = data.aws_iam_policy_document.apply_iam_scoped.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "apply_iam_scoped" {
  role       = aws_iam_role.apply.name
  policy_arn = aws_iam_policy.apply_iam_scoped.arn
}
