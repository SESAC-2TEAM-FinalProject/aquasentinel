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
# PR에서 리소스가 생성될 위험이 없음). sub 클레임은 project_id 기반(위 변수 설명
# 참고 — project_path 재사용 방지 보안 기능 때문에 2026-10-10 전환):
# project_id:<numeric_id>:ref_type:branch:ref:<branch>
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
      values   = ["project_id:${var.gitlab_project_id}:*"]
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
      values   = ["project_id:${var.gitlab_project_id}:ref_type:branch:ref:main"]
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

  # EKS 노드그룹 생성 시 AWS가 AWSServiceRoleForAmazonEKSNodegroup(서비스
  # 연결 역할)이 이미 있는지 GetRole로 확인한다 — 프로젝트 접두사로 좁힐 수
  # 없는 AWS 관리형 리소스라 별도 예외 필요(2026-10-10, apply:seoul
  # [rebuild/2-cluster] 첫 실제 실행에서 "missing permissions for
  # 'iam:GetRole'"로 발견). 역할이 없을 경우를 대비해 CreateServiceLinkedRole도
  # 같이 허용한다.
  statement {
    sid    = "EksServiceLinkedRoleManagement"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:CreateServiceLinkedRole",
    ]
    resources = [
      "arn:aws:iam::*:role/aws-service-role/eks.amazonaws.com/*",
      "arn:aws:iam::*:role/aws-service-role/eks-nodegroup.amazonaws.com/*",
    ]
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

# ---------------------------------------------------------------------------
# 이미지 빌드 CI용 ECR 푸시 역할 — 이 cicd 컴포넌트와 다른 GitLab 프로젝트
# (앱 레포 미러)가 assume한다. 신뢰 당사자가 "GitLab.com 자체"인 OIDC라 위
# plan/apply와 같은 Provider를 project_id 조건만 바꿔 재사용한다(2026-10-11,
# 웹 레포 CI 자동화 — PM 전달 "웹 이미지 빌드·ECR 푸시까지 CI가 할지" 결정).
# apply 역할과 같은 이유로 main 브랜치 파이프라인만 assume 가능 — 미러
# 프로젝트는 pull sync가 main을 갱신할 때 생기는 push 이벤트로 파이프라인이
# 돈다.
# ---------------------------------------------------------------------------

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "build_assume_role" {
  for_each = var.build_projects

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
      values   = ["project_id:${each.value.gitlab_project_id}:ref_type:branch:ref:main"]
    }
  }
}

resource "aws_iam_role" "build" {
  for_each = var.build_projects

  name               = "${local.name_prefix}-gitlab-${each.key}-ecr-push"
  assume_role_policy = data.aws_iam_policy_document.build_assume_role[each.key].json
  tags               = var.tags
}

# ecr:GetAuthorizationToken은 리소스 수준 권한을 지원하지 않아 "*"가 불가피하다
# (docker login 한 번에 전체 레지스트리 인증 토큰을 받는 AWS 쪽 제약 — ECR
# API 전체의 공통 제약이지 이 역할만의 완화는 아니다). 실제 쓰기 권한
# (PutImage 등)은 그 프로젝트의 리포지토리로만 좁힌다.
data "aws_iam_policy_document" "build_ecr_push" {
  for_each = var.build_projects

  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [
      for repo in each.value.ecr_repositories :
      "arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/${repo}"
    ]
  }
}

resource "aws_iam_role_policy" "build_ecr_push" {
  for_each = var.build_projects

  name   = "${local.name_prefix}-gitlab-${each.key}-ecr-push"
  role   = aws_iam_role.build[each.key].id
  policy = data.aws_iam_policy_document.build_ecr_push[each.key].json
}
