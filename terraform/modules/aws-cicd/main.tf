locals {
  name_prefix = var.project_name
}

# ---------------------------------------------------------------------------
# GitLab.com을 직접 신뢰하는 OIDC (2026-10-09, EKS-IRSA 전제에서 전환)
#
# 앞서 EKS 클러스터 안의 GitLab Runner가 IRSA로 AWS 권한을 받는 설계로
# 한 번 바꿨었는데, AquaSentinel_GitLab_CI_도입_근거_팀공유용_2026-10-08.md
# "약점과 대응" 표에 이미 "Terraform 작업을 클러스터 안 러너에서 돌리면
# 위험 — plan·apply는 기본 러너나 로컬에서 실행"이라고 결론 나 있었다
# (Terraform이 그 클러스터 자체를 destroy/수정하는데, 실행 환경이 그
# 클러스터 안에 있으면 apply가 클러스터를 망가뜨리는 순간 그걸 고칠 CI도
# 같이 사라지는 순환 의존이 생김). 기본 러너(GitLab.com 공유 러너)나
# 로컬에서 돌리려면 IRSA(그 EKS 클러스터 안 파드에게만 발급되는 자격증명)를
# 쓸 수 없으므로, GitLab.com 자체를 발급자로 하는 별도 OIDC Provider가
# 필요하다 — 예전 GitHub Actions OIDC와 같은 구조, 발급자만 바뀐 것.
#
# GitLab 공식 AWS 연동 가이드(docs.gitlab.com/ee/ci/cloud_services/aws/)를
# 그대로 따른다: ID 토큰의 aud를 "https://aws"로 커스터마이징하고,
# OIDC Provider의 client_id_list도 그에 맞춘다.
# ---------------------------------------------------------------------------

data "tls_certificate" "gitlab" {
  url = "https://gitlab.com"
}

resource "aws_iam_openid_connect_provider" "gitlab" {
  url             = "https://gitlab.com"
  client_id_list  = ["https://aws"]
  thumbprint_list = [data.tls_certificate.gitlab.certificates[0].sha1_fingerprint]

  tags = var.tags
}

# plan 역할 — 프로젝트 내 모든 브랜치/MR 파이프라인에서 assume 가능(읽기전용이라
# PR에서 리소스가 생성될 위험이 없음). sub 클레임 형식은 GitLab 공식 문서 기준:
# project_path:<group>/<project>:ref_type:branch:ref:<branch>
data "aws_iam_policy_document" "plan_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gitlab.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "gitlab.com:aud"
      values   = ["https://aws"]
    }

    condition {
      test     = "StringLike"
      variable = "gitlab.com:sub"
      values   = ["project_path:${var.gitlab_project_path}:*"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "${local.name_prefix}-gitlab-terraform-plan"
  assume_role_policy = data.aws_iam_policy_document.plan_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# apply 역할 — main 브랜치의 push 파이프라인(merge 후 실행)만 assume 가능.
# ref_protected 클레임까지 같이 걸고 싶지만 StringLike/StringEquals 조건은
# 리스트 내 OR로만 묶이고 AND는 별도 condition 블록으로 쌓아야 하므로,
# sub에 ref:main을 명시하는 것만으로 "protected 브랜치가 아니면 애초에
# push를 못 한다"(GitLab 브랜치 보호 설정)에 의존한다 — 브랜치 보호 설정이
# 이 역할의 안전성 전제조건이다(팀 GitLab 프로젝트 설정에서 main을 protected로
# 지정해야 함, 레포 이전 체크리스트에 포함).
data "aws_iam_policy_document" "apply_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gitlab.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "gitlab.com:aud"
      values   = ["https://aws"]
    }

    condition {
      test     = "StringEquals"
      variable = "gitlab.com:sub"
      values   = ["project_path:${var.gitlab_project_path}:ref_type:branch:ref:main"]
    }
  }
}

resource "aws_iam_role" "apply" {
  name               = "${local.name_prefix}-gitlab-terraform-apply"
  assume_role_policy = data.aws_iam_policy_document.apply_assume_role.json
  tags               = var.tags
}

# PowerUserAccess는 IAM/Organizations 관리를 제외한 전 서비스를 커버한다.
# 이 프로젝트의 모듈(aws-eks/aws-data/aws-ingress/aws-dns)이 전부 IAM 역할·정책을
# 직접 만들기 때문에, apply 역할도 IAM 권한이 필요하다 — 이건 Terraform으로 IAM을
# 관리하는 모든 CI 파이프라인이 구조적으로 안고 가는 한계다(완전한 최소권한 불가).
# 대신 아래 커스텀 정책으로 "${project_name}-*로 시작하는 IAM 엔티티만" 건드릴 수
# 있게 범위를 좁혀 자기권한상승(self-privilege-escalation) 반경을 제한한다.
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
  # 범위를 좁힐 수 없다 — eks 모듈이 OIDC provider를 관리할 때 필요한 예외.
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
  name   = "${local.name_prefix}-gitlab-apply-iam-scoped"
  policy = data.aws_iam_policy_document.apply_iam_scoped.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "apply_poweruser" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy_attachment" "apply_iam_scoped" {
  role       = aws_iam_role.apply.name
  policy_arn = aws_iam_policy.apply_iam_scoped.arn
}
