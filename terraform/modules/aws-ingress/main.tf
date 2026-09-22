locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller용 IRSA
#
# 이 모듈은 ALB 자체를 만들지 않는다. 컨트롤러가 클러스터 안에서 k8s Ingress를
# 보고 ALB/타깃그룹을 스스로 생성·수정·삭제할 수 있도록 IAM 역할만 미리 준비해둔다.
# 컨트롤러 설치(Helm) 자체는 추후 CNCF/앱 레이어 작업 범위다.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lbc_assume" {
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

resource "aws_iam_role" "lbc" {
  name               = "${local.name_prefix}-aws-lbc-role"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume.json
  tags               = var.tags
}

# 공식 정책 원문: https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
# 컨트롤러 버전을 올릴 때는 위 URL과 diff해서 최신 여부를 확인할 것.
resource "aws_iam_policy" "lbc" {
  name   = "${local.name_prefix}-aws-lbc-policy"
  policy = file("${path.module}/policies/aws-load-balancer-controller-iam-policy.json")
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}
