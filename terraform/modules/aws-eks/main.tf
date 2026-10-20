locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # -------------------------------------------------------------------------
  # 코어 애드온(coredns·EBS CSI 컨트롤러) 배치 제어 (2026-10-15 추가)
  #
  # 배경: coredns 2벌과 ebs-csi-controller 2벌이 "2벌이니 안전"해 보였지만
  # 실측해보니 4개 전부 같은 스팟 노드 한 대(ip-10-0-47-204)에 앉아 있었다.
  # 두 애드온의 기본 anti-affinity가 preferred(권장)라서, 스케줄 여유가
  # 빠듯하면 그냥 한 노드에 몰린다. 그 노드가 스팟 회수되면
  #   - coredns 0개            → 클러스터 DNS 전면 다운
  #   - ebs-csi-controller 0개 → 볼륨 attach/detach 불가(CNPG 복구까지 막힘)
  # 가 동시에 터진다.
  # -------------------------------------------------------------------------

  # node_taints(AWS API 표기)를 쿠버네티스 toleration 표기로 변환한다.
  # 노드그룹 taint가 바뀌어도 애드온 toleration이 자동으로 따라오게 하려고
  # 하드코딩하지 않고 var.node_taints에서 파생시킨다.
  taint_effect_to_k8s = {
    NO_SCHEDULE        = "NoSchedule"
    NO_EXECUTE         = "NoExecute"
    PREFER_NO_SCHEDULE = "PreferNoSchedule"
  }

  core_addon_tolerations = [
    for t in var.node_taints : {
      key      = t.key
      operator = "Equal"
      value    = t.value
      effect   = local.taint_effect_to_k8s[t.effect]
    }
  ]

  # "서로 다른 노드에 반드시 흩어져라"를 강제한다(DoNotSchedule).
  # preferred가 아니라 required여야 하는 이유는 위 배경 그대로다.
  core_addon_topology_spread = {
    for name, labels in {
      coredns = { "k8s-app" = "kube-dns" }
      ebs_csi = { "app" = "ebs-csi-controller" }
      } : name => [{
        maxSkew           = 1
        topologyKey       = "kubernetes.io/hostname"
        whenUnsatisfiable = "DoNotSchedule"
        labelSelector     = { matchLabels = labels }
    }]
  }
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

  labels = var.node_labels

  dynamic "taint" {
    for_each = var.node_taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
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

# vpc-cni 애드온 설정 — 켠 기능만 모아 JSON 하나로 넘긴다. 둘 다 끄면 null(애드온 기본값).
# enable_network_policy 를 false 로 두면 만들어지는 JSON 이 이전과 똑같아(키가 추가되지 않음)
# 이 코드를 머지해도 아무것도 바뀌지 않는다 — 실제로 켜는 건 컴포넌트 쪽 변수(2026-10-14, egress 계층 1).
locals {
  vpc_cni_config = merge(
    var.enable_prefix_delegation ? { env = { ENABLE_PREFIX_DELEGATION = "true" } } : {},
    var.enable_network_policy ? { enableNetworkPolicy = "true" } : {},
  )
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "vpc-cni"
  addon_version = var.addon_versions.vpc_cni != "" ? var.addon_versions.vpc_cni : null

  configuration_values = length(local.vpc_cni_config) > 0 ? jsonencode(local.vpc_cni_config) : null

  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "coredns"
  addon_version = var.addon_versions.coredns != "" ? var.addon_versions.coredns : null

  # 배치 제어 — locals의 "코어 애드온 배치 제어" 주석 참고.
  # replicaCount를 3으로 올린 이유: hostname DoNotSchedule 제약 때문에 3벌은
  # 반드시 서로 다른 노드 3대에 흩어진다. 카펜터 스팟 노드는 2대뿐이므로
  # "최소 1벌은 고정 노드그룹(온디맨드)에 앉는다"가 수학적으로 보장된다 —
  # 스팟 2대가 동시에 회수돼도 DNS가 살아남는다. (coredns는 파드당 100m/70Mi로
  # 가벼워서 1벌 추가 비용이 사실상 없다.)
  # tolerations가 없으면 고정 노드그룹에 아예 못 앉아 위 보장이 성립하지 않는다.
  configuration_values = jsonencode({
    replicaCount              = 3
    tolerations               = local.core_addon_tolerations
    topologySpreadConstraints = local.core_addon_topology_spread["coredns"]
  })

  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.default]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "kube-proxy"
  addon_version = var.addon_versions.kube_proxy != "" ? var.addon_versions.kube_proxy : null

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
  addon_version            = var.addon_versions.ebs_csi != "" ? var.addon_versions.ebs_csi : null
  service_account_role_arn = aws_iam_role.ebs_csi[0].arn

  # 컨트롤러 배치 제어 — coredns와 같은 이유·같은 방식(locals 주석 참고).
  # 컨트롤러가 전멸하면 볼륨 attach/detach가 멈춰서, 노드가 복구돼도
  # CNPG가 자기 EBS를 다시 붙이지 못한다. DNS만큼이나 복구의 전제 조건이라
  # 동일하게 3벌 + 노드 분산으로 간다.
  # node 쪽은 DaemonSet이라 손대지 않는다(이미 5대 전부에 떠 있음).
  configuration_values = jsonencode({
    controller = {
      replicaCount              = 3
      tolerations               = local.core_addon_tolerations
      topologySpreadConstraints = local.core_addon_topology_spread["ebs_csi"]
    }
  })

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

# ---------------------------------------------------------------------------
# 그룹 접근 — 접근 정책 대신 쿠버네티스 그룹만 붙인다(2026-10-14, 알람 묶음 C).
# 관리형 접근 정책은 네임스페이스 단위가 가장 좁아 "파드 하나에 exec" 같은
# 권한을 표현할 수 없다. 범위는 그 그룹을 묶는 RBAC(Role/RoleBinding)가 정하고,
# RBAC 는 gitops 가 관리한다 — 그룹 이름이 둘을 잇는 고리다.
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "group" {
  for_each = var.group_access_entries

  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = each.value.principal_arn
  kubernetes_groups = each.value.kubernetes_groups
  type              = "STANDARD"
}
