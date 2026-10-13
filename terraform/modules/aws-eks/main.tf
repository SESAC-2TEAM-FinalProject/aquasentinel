locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ---------------------------------------------------------------------------
# EKS 클러스터 IAM
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name_prefix}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------------------------------------------------------------------------
# EKS 클러스터
# ---------------------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_public_access  = var.endpoint_public_access
    endpoint_private_access = var.endpoint_private_access
  }

  # EKS Access Entries API를 켜서 aws-access 모듈이 팀원 3명을 등록할 수 있게 한다.
  # 클러스터 생성자에게도 admin을 자동 부여해 부트스트랩 단계에서 락아웃을 방지한다.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = merge(var.tags, {
    Name = var.cluster_name
  })

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# ---------------------------------------------------------------------------
# OIDC Provider — EBS CSI뿐 아니라 이후 ESO, AWS LB Controller의 IRSA가
# 전부 이 provider 하나를 재사용한다.
# ---------------------------------------------------------------------------

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]

  tags = var.tags
}

# ---------------------------------------------------------------------------
# 노드그룹 IAM
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name_prefix}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# SSM — 카펜터 공식 KarpenterNodeRole에도 포함되는 정책(AMI 리졸브와는 무관하고
# 노드에 대한 세션 매니저 접속용). 2026-10-13 보안 하드닝 검토에서 노드 역할에
# 빠져있는 걸 확인했고, 보안 강화안(EKS 퍼블릭 엔드포인트 CIDR 제한 시 SSM
# 포트포워딩 브릿지)에도 재사용할 수 있어 여기서 같이 추가한다.
resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 카펜터가 프로비저닝하는 노드용 인스턴스 프로필. 관리형 노드그룹(아래
# aws_eks_node_group.default)은 EKS가 인스턴스 프로필을 내부적으로 자동
# 생성해주지만, 카펜터의 EC2NodeClass는 명시적인 인스턴스 프로필을 받아야
# 해서 기존 노드 역할(aws_iam_role.node)을 그대로 재사용해 하나 만들어둔다
# (새 역할을 따로 안 만드는 이유: 카펜터가 띄우는 노드도 결국 기존 관리형
# 노드그룹의 노드와 동일한 워크로드를 수용하므로 권한을 분리할 이유가 없음).
resource "aws_iam_instance_profile" "node" {
  name = "${local.name_prefix}-eks-node-profile"
  role = aws_iam_role.node.name
  tags = var.tags
}

# ---------------------------------------------------------------------------
# 노드그룹 — 커스텀 launch template으로 max-pods를 EKS 관리형 부트스트랩에 병합한다.
# AMI를 직접 지정하지 않으므로 EKS가 관리형 AMI(기본값 AL2023_x86_64_STANDARD)를
# 그대로 쓴다. AL2023은 `/etc/eks/bootstrap.sh`(AL2 전용 레거시 스크립트) 자체가
# 없어 그 스크립트를 호출하는 user_data는 조용히 실패한다(2026-10-07 서울 재구축
# 테스트에서 실제로 발견 — Prefix Delegation은 vpc-cni 애드온에서 켜졌는데도
# 노드가 기본 max-pods 35로 등록돼 두 노드가 꽉 차서 파드가 Pending에 멈췄음).
# AL2023은 `nodeadm`의 NodeConfig(YAML, MIME 파트 Content-Type은
# application/node.eks.aws)로 병합해야 한다.
# ---------------------------------------------------------------------------

resource "aws_launch_template" "node" {
  name_prefix            = "${local.name_prefix}-ng-"
  update_default_version = true

  user_data = base64encode(<<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="==BOUNDARY=="

    --==BOUNDARY==
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      kubelet:
        config:
          maxPods: ${var.max_pods_per_node}

    --==BOUNDARY==--
  EOT
  )

  tag_specifications {
    resource_type = "instance"

    tags = merge(var.tags, {
      Name = "${local.name_prefix}-node"
    })
  }

  tags = var.tags
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name_prefix}-default"
  node_role_arn   = aws_iam_role.node.arn
  # 클러스터 vpc_config(위)와 달리 일부러 var.private_subnet_ids를 그대로 안 쓴다 —
  # 관리형 노드그룹은 subnet_ids가 바뀌면 AWS API 특성상 무조건 강제 교체(destroy+recreate)
  # 된다(2026-10-13, 3번째 AZ 추가 시도 중 plan으로 직접 확인). 이미 CNPG/NATS가 떠 있는
  # 노드그룹이라 조용히 날아가면 안 되므로, 서브넷 목록을 생성 당시 값으로 고정해서
  # private_subnet_ids가 나중에 늘어나도(카펜터용 3번째 AZ 추가 등) 이 노드그룹은 전혀
  # 영향받지 않게 분리했다. 카펜터 NodePool/EC2NodeClass가 3 AZ 전체를 담당한다.
  subnet_ids = var.node_group_subnet_ids

  instance_types = var.node_instance_types
  capacity_type  = var.node_capacity_type

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

# ---------------------------------------------------------------------------
# 코어 애드온
# ---------------------------------------------------------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"

  configuration_values = var.enable_prefix_delegation ? jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
    }
  }) : null

  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"

  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.default]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_update = "OVERWRITE"
}

# ---------------------------------------------------------------------------
# EBS CSI Driver — Prometheus/Loki/Grafana의 PVC(4주차)가 이걸 전제로 한다.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ebs_csi_assume" {
  count = var.enable_ebs_csi ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  count              = var.enable_ebs_csi ? 1 : 0
  name               = "${local.name_prefix}-ebs-csi-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count      = var.enable_ebs_csi ? 1 : 0
  role       = aws_iam_role.ebs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  count                    = var.enable_ebs_csi ? 1 : 0
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi[0].arn

  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.default]
}

# ---------------------------------------------------------------------------
# 팀원 접근권한 (EKS Access Entries) — 구 aws-access 모듈/컴포넌트 흡수
# (2026-10-09 구조 개선: 독립 컴포넌트로 분리할 이유가 약해 EKS에 통합.
#  클러스터가 존재해야만 의미 있는 리소스라 별도 state로 쪼갤 가치가 없었음)
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "team" {
  for_each = { for m in var.team_members : m.name => m }

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.iam_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "team" {
  for_each = aws_eks_access_entry.team

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = var.access_policy_arn

  access_scope {
    type = "cluster"
  }
}

# ---------------------------------------------------------------------------
# 읽기 전용 접근 — CI plan 역할처럼 클러스터를 읽기만 하는 주체(2026-10-13).
# 3-gitops plan 이 kubernetes_manifest(Argo CD Application) · 시크릿을 읽는데
# plan 역할이 access entry 에 없어 "Unauthorized" 로 실패했다(apply 역할은 클러스터
# 생성자라 bootstrap_cluster_creator_admin_permissions 로 이미 관리자).
# team_members(관리자)에 넣지 않는 이유: plan 은 어느 브랜치 MR 에서든 도는 잡이라
# 쓰기 권한까지 주면 범위가 너무 넓다. AdminView 는 시크릿까지 읽고 쓰기는 없다.
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "readonly" {
  for_each = toset(var.readonly_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "readonly" {
  for_each = aws_eks_access_entry.readonly

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"

  access_scope {
    type = "cluster"
  }
}
