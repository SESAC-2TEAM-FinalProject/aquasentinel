# 카펜터(Karpenter) 컨트롤러 IRSA + 인터럽션 큐 — 가용성/DR 재구축 개선안
# (2026-10-13) 2단계. IAM 정책은 카펜터 공식 CloudFormation 템플릿
# (aws/karpenter-provider-aws, getting-started-with-karpenter/cloudformation.yaml,
# 2026-10-13 확인)의 NodeLifecyclePolicy/IAMIntegrationPolicy/EKSIntegrationPolicy/
# InterruptionPolicy/ResourceDiscoveryPolicy를 그대로 Terraform으로 옮긴 것이다.
# ZonalShiftPolicy(ARC Zonal Shift)는 이 프로젝트에서 안 쓰는 기능이라 제외했다.
#
# 노드 역할은 기존 aws_iam_role.node(modules/aws-eks)를 그대로 재사용한다 —
# 카펜터가 띄우는 노드도 관리형 노드그룹의 노드와 동일한 워크로드를 수용하므로
# 권한을 분리할 이유가 없다. 인스턴스 프로필(aws_iam_instance_profile.node)도
# 같은 모듈에서 만들어둔 걸 쓴다.

data "aws_partition" "current" {}

locals {
  karpenter_cluster_name = module.eks.cluster_name
  karpenter_account_id   = data.aws_caller_identity.current.account_id
  karpenter_partition    = data.aws_partition.current.partition
}

# ---------------------------------------------------------------------------
# NodeLifecyclePolicy — EC2 인스턴스/launch template 생명주기
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "karpenter_node_lifecycle" {
  statement {
    sid    = "AllowScopedEC2InstanceAccessActions"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
    ]
    resources = [
      "arn:${local.karpenter_partition}:ec2:${var.region}::image/*",
      "arn:${local.karpenter_partition}:ec2:${var.region}::snapshot/*",
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:security-group/*",
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:subnet/*",
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:capacity-reservation/*",
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:placement-group/*",
    ]
  }

  statement {
    sid       = "AllowScopedEC2LaunchTemplateAccessActions"
    effect    = "Allow"
    actions   = ["ec2:RunInstances", "ec2:CreateFleet"]
    resources = ["arn:${local.karpenter_partition}:ec2:${var.region}:*:launch-template/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${local.karpenter_cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid    = "AllowScopedEC2InstanceActionsWithTags"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
    ]
    resources = [
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:fleet/*",
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:instance/*",
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:volume/*",
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:network-interface/*",
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:launch-template/*",
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:spot-instances-request/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${local.karpenter_cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [local.karpenter_cluster_name]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid     = "AllowScopedResourceCreationTagging"
    effect  = "Allow"
    actions = ["ec2:CreateTags"]
    resources = [
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:fleet/*",
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:instance/*",
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:volume/*",
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:network-interface/*",
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:launch-template/*",
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:spot-instances-request/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${local.karpenter_cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [local.karpenter_cluster_name]
    }
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedResourceTagging"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:${local.karpenter_partition}:ec2:${var.region}:*:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${local.karpenter_cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [local.karpenter_cluster_name]
    }
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["eks:eks-cluster-name", "karpenter.sh/nodeclaim", "Name"]
    }
  }

  statement {
    sid    = "AllowScopedDeletion"
    effect = "Allow"
    actions = [
      "ec2:TerminateInstances",
      "ec2:RebootInstances",
      "ec2:DeleteLaunchTemplate",
    ]
    resources = [
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:instance/*",
      "arn:${local.karpenter_partition}:ec2:${var.region}:*:launch-template/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${local.karpenter_cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }
}

resource "aws_iam_policy" "karpenter_node_lifecycle" {
  name   = "${local.name_prefix}-karpenter-node-lifecycle"
  policy = data.aws_iam_policy_document.karpenter_node_lifecycle.json
  tags   = var.tags
}

# ---------------------------------------------------------------------------
# IAMIntegrationPolicy — 노드 역할 PassRole + 인스턴스 프로필 관리
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "karpenter_iam_integration" {
  statement {
    sid       = "AllowPassingInstanceRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [module.eks.node_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com", "ec2.amazonaws.com.cn"]
    }
  }

  statement {
    sid       = "AllowScopedInstanceProfileCreationActions"
    effect    = "Allow"
    actions   = ["iam:CreateInstanceProfile"]
    resources = ["arn:${local.karpenter_partition}:iam::${local.karpenter_account_id}:instance-profile/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${local.karpenter_cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [local.karpenter_cluster_name]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/topology.kubernetes.io/region"
      values   = [var.region]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedInstanceProfileTagActions"
    effect    = "Allow"
    actions   = ["iam:TagInstanceProfile"]
    resources = ["arn:${local.karpenter_partition}:iam::${local.karpenter_account_id}:instance-profile/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${local.karpenter_cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/topology.kubernetes.io/region"
      values   = [var.region]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${local.karpenter_cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [local.karpenter_cluster_name]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/topology.kubernetes.io/region"
      values   = [var.region]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid    = "AllowScopedInstanceProfileActions"
    effect = "Allow"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:DeleteInstanceProfile",
    ]
    resources = ["arn:${local.karpenter_partition}:iam::${local.karpenter_account_id}:instance-profile/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${local.karpenter_cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/topology.kubernetes.io/region"
      values   = [var.region]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }
}

resource "aws_iam_policy" "karpenter_iam_integration" {
  name   = "${local.name_prefix}-karpenter-iam-integration"
  policy = data.aws_iam_policy_document.karpenter_iam_integration.json
  tags   = var.tags
}

# ---------------------------------------------------------------------------
# EKSIntegrationPolicy — API 서버 엔드포인트 디스커버리
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "karpenter_eks_integration" {
  statement {
    sid       = "AllowAPIServerEndpointDiscovery"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${local.karpenter_partition}:eks:${var.region}:${local.karpenter_account_id}:cluster/${local.karpenter_cluster_name}"]
  }
}

resource "aws_iam_policy" "karpenter_eks_integration" {
  name   = "${local.name_prefix}-karpenter-eks-integration"
  policy = data.aws_iam_policy_document.karpenter_eks_integration.json
  tags   = var.tags
}

# ---------------------------------------------------------------------------
# ResourceDiscoveryPolicy — 읽기 전용 리소스 탐색(인스턴스 타입/가격/AMI 등)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "karpenter_resource_discovery" {
  statement {
    sid    = "AllowRegionalReadActions"
    effect = "Allow"
    actions = [
      "ec2:DescribeCapacityReservations",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribePlacementGroups",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "AllowSSMReadActions"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:${local.karpenter_partition}:ssm:${var.region}::parameter/aws/service/*"]
  }

  statement {
    sid       = "AllowPricingReadActions"
    effect    = "Allow"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  statement {
    sid       = "AllowUnscopedInstanceProfileListAction"
    effect    = "Allow"
    actions   = ["iam:ListInstanceProfiles"]
    resources = ["*"]
  }

  statement {
    sid       = "AllowInstanceProfileReadActions"
    effect    = "Allow"
    actions   = ["iam:GetInstanceProfile"]
    resources = ["arn:${local.karpenter_partition}:iam::${local.karpenter_account_id}:instance-profile/*"]
  }
}

resource "aws_iam_policy" "karpenter_resource_discovery" {
  name   = "${local.name_prefix}-karpenter-resource-discovery"
  policy = data.aws_iam_policy_document.karpenter_resource_discovery.json
  tags   = var.tags
}

# ---------------------------------------------------------------------------
# 스팟 중단 알림 인터럽션 큐 — EventBridge가 이 큐로 이벤트를 보내면 카펜터
# 컨트롤러가 폴링해서 노드를 선제적으로 드레인/교체한다.
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = local.karpenter_cluster_name
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

data "aws_iam_policy_document" "karpenter_interruption_queue" {
  statement {
    sid    = "EC2InterruptionPolicy"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.karpenter_interruption.arn]
  }

  statement {
    sid    = "DenyHTTP"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.karpenter_interruption.arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id
  policy    = data.aws_iam_policy_document.karpenter_interruption_queue.json
}

data "aws_iam_policy_document" "karpenter_interruption" {
  statement {
    sid    = "AllowInterruptionQueueActions"
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
    ]
    resources = [aws_sqs_queue.karpenter_interruption.arn]
  }
}

resource "aws_iam_policy" "karpenter_interruption" {
  name   = "${local.name_prefix}-karpenter-interruption"
  policy = data.aws_iam_policy_document.karpenter_interruption.json
  tags   = var.tags
}

# EventBridge 규칙 4종 — 공식 템플릿의 5종(+CapacityReservationInterruptionRule)
# 중 용량 예약(ODCR)은 이 프로젝트에서 안 쓰므로 제외했다.
resource "aws_cloudwatch_event_rule" "karpenter_health" {
  name = "${local.name_prefix}-karpenter-health-event"
  event_pattern = jsonencode({
    source        = ["aws.health"]
    "detail-type" = ["AWS Health Event"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "karpenter_health" {
  rule = aws_cloudwatch_event_rule.karpenter_health.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_spot_interruption" {
  name = "${local.name_prefix}-karpenter-spot-interruption"
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Spot Instance Interruption Warning"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "karpenter_spot_interruption" {
  rule = aws_cloudwatch_event_rule.karpenter_spot_interruption.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_rebalance" {
  name = "${local.name_prefix}-karpenter-rebalance"
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Instance Rebalance Recommendation"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "karpenter_rebalance" {
  rule = aws_cloudwatch_event_rule.karpenter_rebalance.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_instance_state_change" {
  name = "${local.name_prefix}-karpenter-instance-state-change"
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Instance State-change Notification"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "karpenter_instance_state_change" {
  rule = aws_cloudwatch_event_rule.karpenter_instance_state_change.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

# ---------------------------------------------------------------------------
# 카펜터 컨트롤러 IRSA — 네임스페이스/ServiceAccount는 3-gitops에서 만들
# Helm Application(5단계)의 serviceAccount 설정과 반드시 일치해야 한다.
# ---------------------------------------------------------------------------

module "karpenter_irsa" {
  source = "../../../modules/aws-irsa"

  role_name                  = "${local.name_prefix}-karpenter-controller"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  namespace_service_accounts = ["kube-system:karpenter"]

  policy_arns = {
    node_lifecycle     = aws_iam_policy.karpenter_node_lifecycle.arn
    iam_integration    = aws_iam_policy.karpenter_iam_integration.arn
    eks_integration    = aws_iam_policy.karpenter_eks_integration.arn
    interruption       = aws_iam_policy.karpenter_interruption.arn
    resource_discovery = aws_iam_policy.karpenter_resource_discovery.arn
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# 디스커버리 태그 — 카펜터 EC2NodeClass의 subnetSelectorTerms/
# securityGroupSelectorTerms가 이 태그로 서브넷·보안그룹을 찾는다(5~6단계,
# 아직 미작성). 서브넷은 3 AZ 전부(private_app_subnet_ids — 2a/2c/2b) 대상으로
# 해서, 컨트롤플레인은 못 들어가는 2b라도 워커 노드는 뜰 수 있게 한다.
# modules/aws-network를 직접 건드리지 않고 aws_ec2_tag로 기존 리소스에
# 태그만 추가하는 방식을 택했다 — 네트워크 state를 건드리지 않기 위함.
# ---------------------------------------------------------------------------

resource "aws_ec2_tag" "karpenter_subnet_discovery" {
  for_each    = toset(data.terraform_remote_state.network.outputs.private_app_subnet_ids)
  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = local.karpenter_cluster_name
}

resource "aws_ec2_tag" "karpenter_sg_discovery" {
  resource_id = module.eks.cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = local.karpenter_cluster_name
}
